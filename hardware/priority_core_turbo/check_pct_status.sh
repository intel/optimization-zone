#!/usr/bin/env bash
#
# check_pct_status.sh — verify Intel Priority Core Turbo (PCT) / CLOS status.
#
# Latest behavior:
#   - Parse SST-TF bucket capacity from:
#       intel-speed-select turbo-freq info -l <TDP_LEVEL>
#   - Treat bucket-0 as the PCT bucket by default
#   - Correctly count PCT capacity ONCE PER PACKAGE/SOCKET, not once per powerdomain anchor
#   - Report PCT reporting anchors, active packages, PCT cores/package, physical/logical budget
#   - Print current CLOS distribution
#   - Print TARGET_CLOS CPU list and compare its count to PCT logical budget
#
# Config via env:
#   TARGET_CLOS=0     # which CLOS to print as HP/PCT list
#   CHUNK=64          # CPUs per get-assoc call
#   HP_BUCKET=0       # bucket-0 is the PCT bucket by default
#   TDP_LEVEL=1       # intel-speed-select turbo-freq info -l <TDP_LEVEL>
#   DEBUG_MAP=0       # 1 = show tmp_map with invisible chars
#
# Important interpretation:
#   - intel-speed-select may repeat bucket-0/1/2 under multiple powerdomain anchors.
#   - Do NOT sum bucket-0 across all anchors.
#   - For PCT capacity, group by package/socket and count bucket-0 once per package.
#

set -euo pipefail

TARGET_CLOS="${TARGET_CLOS:-0}"
CHUNK="${CHUNK:-64}"
HP_BUCKET="${HP_BUCKET:-0}"
TDP_LEVEL="${TDP_LEVEL:-1}"
DEBUG_MAP="${DEBUG_MAP:-0}"

SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  SUDO="sudo"
fi

RESULTS_DIR="/workspace/benchmarks/results"
mkdir -p "${RESULTS_DIR}"

print_header() {
  echo "------------------------------------------------------------"
  echo "$1"
  echo "------------------------------------------------------------"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

count_cpulist() {
  python3 - "$1" <<'PY'
import sys
s = sys.argv[1].strip()
count = 0
if s:
    for part in s.split(','):
        part = part.strip()
        if not part:
            continue
        if '-' in part:
            a, b = map(int, part.split('-', 1))
            count += b - a + 1
        else:
            count += 1
print(count)
PY
}

get_threads_per_core() {
  local tpc
  tpc="$(lscpu | awk -F: '/Thread\(s\) per core/{gsub(/[[:space:]]/,"",$2); print $2}' | head -n1)"
  if [[ -z "${tpc:-}" ]]; then
    echo 1
  else
    echo "$tpc"
  fi
}

get_assoc_for_cpulist() {
  local cpu_list="$1"
  $SUDO intel-speed-select -c "$cpu_list" core-power get-assoc 2>&1 |
    while IFS= read -r line; do
      if [[ "$line" =~ cpu-([0-9]+) ]]; then
        cur_cpu="${BASH_REMATCH[1]}"
      fi
      if [[ "$line" =~ clos:([0-9]+) ]]; then
        printf "%s %s\n" "${cur_cpu:-?}" "${BASH_REMATCH[1]}"
      fi
    done
}

detect_pct_capacity() {
  local tdp_level="${1:-1}"
  local bucket="${2:-0}"
  local out

  out="$($SUDO intel-speed-select turbo-freq info -l "$tdp_level" 2>&1 || true)"

  if ! echo "$out" | grep -q "high-priority-cores-count"; then
    echo "PCT_BUCKET=bucket-${bucket}"
    echo "PCT_REPORTING_ANCHORS=0"
    echo "PCT_ACTIVE_PACKAGES=0"
    echo "PCT_CORES_PER_PACKAGE=0"
    echo "PCT_TOTAL_PHYSICAL_CORES=0"
    echo "PCT_MAX_FREQ_MHZ=0"
    echo "PCT_DOMAIN_ANCHORS="
    echo "PCT_PACKAGE_SUMMARY="
    return 0
  fi

  PCT_TF_OUT="$out" python3 - "$bucket" <<'PY'
import os
import re
import sys
from collections import defaultdict

want_bucket = f"bucket-{sys.argv[1]}"
lines = os.environ.get('PCT_TF_OUT', '').splitlines()

anchors = []
cur_pkg = None
cur_die = None
cur_pd = None
cur_cpu = None
cur_bucket = None

for line in lines:
    s = line.strip()

    m = re.match(r'package-(\d+)', s)
    if m:
        cur_pkg = int(m.group(1))
        continue

    m = re.match(r'die-(\d+)', s)
    if m:
        cur_die = int(m.group(1))
        continue

    m = re.match(r'powerdomain-(\d+)', s)
    if m:
        cur_pd = int(m.group(1))
        cur_cpu = None
        continue

    if s == 'cpu-None':
        cur_cpu = None
        continue

    m = re.match(r'cpu-(\d+)', s)
    if m:
        cur_cpu = int(m.group(1))
        continue

    m = re.match(r'bucket-(\d+)', s)
    if m:
        cur_bucket = f"bucket-{m.group(1)}"
        continue

    if cur_bucket == want_bucket and 'high-priority-cores-count:' in s:
        count = int(re.sub(r'.*high-priority-cores-count:\s*', '', s).split()[0])
        anchors.append({
            'package': cur_pkg,
            'die': cur_die,
            'powerdomain': cur_pd,
            'cpu': cur_cpu,
            'count': count,
            'freq': None,
        })
        continue

    if cur_bucket == want_bucket and 'high-priority-max-level-0-frequency(MHz):' in s:
        freq = int(re.sub(r'.*frequency\(MHz\):\s*', '', s).split()[0])
        if anchors:
            anchors[-1]['freq'] = freq
        continue

# Keep only anchors that have a real CPU. cpu-None sections do not expose HP buckets.
active_anchors = [d for d in anchors if d['cpu'] is not None]

if not active_anchors:
    print(f'PCT_BUCKET={want_bucket}')
    print('PCT_REPORTING_ANCHORS=0')
    print('PCT_ACTIVE_PACKAGES=0')
    print('PCT_CORES_PER_PACKAGE=0')
    print('PCT_TOTAL_PHYSICAL_CORES=0')
    print('PCT_MAX_FREQ_MHZ=0')
    print('PCT_DOMAIN_ANCHORS=')
    print('PCT_PACKAGE_SUMMARY=')
    raise SystemExit(0)

# Correct capacity model:
# Bucket data can repeat under multiple powerdomain anchors.
# PCT capacity is counted once per package/socket.
by_pkg = defaultdict(list)
for d in active_anchors:
    by_pkg[d['package']].append(d)

pkg_counts = {}
pkg_freqs = {}
for pkg, ds in sorted(by_pkg.items()):
    counts = sorted(set(d['count'] for d in ds))
    freqs = sorted(set(d['freq'] for d in ds if d['freq'] is not None))
    # Normally all reporting anchors in a package agree.
    # If not, use the smallest count as the safe PCT bucket capacity for that package.
    pkg_counts[pkg] = min(counts) if counts else 0
    pkg_freqs[pkg] = max(freqs) if freqs else None

active_packages = len(pkg_counts)
total_physical = sum(pkg_counts.values())
all_counts = sorted(set(pkg_counts.values()))
all_freqs = sorted(set(v for v in pkg_freqs.values() if v is not None))

domain_anchors = ','.join(
    f"pkg{d['package']}/die{d['die']}/pd{d['powerdomain']}/cpu{d['cpu']}:cores{d['count']}:freq{d['freq']}"
    for d in active_anchors
)

package_summary = ','.join(
    f"pkg{pkg}:cores{pkg_counts[pkg]}:freq{pkg_freqs[pkg]}:anchors{len(by_pkg[pkg])}"
    for pkg in sorted(pkg_counts)
)

print(f'PCT_BUCKET={want_bucket}')
print(f'PCT_REPORTING_ANCHORS={len(active_anchors)}')
print(f'PCT_ACTIVE_PACKAGES={active_packages}')
print(f"PCT_CORES_PER_PACKAGE={','.join(map(str, all_counts))}")
print(f'PCT_TOTAL_PHYSICAL_CORES={total_physical}')
print(f"PCT_MAX_FREQ_MHZ={','.join(map(str, all_freqs)) if all_freqs else 'unknown'}")
print(f'PCT_DOMAIN_ANCHORS={domain_anchors}')
print(f'PCT_PACKAGE_SUMMARY={package_summary}')
PY
}

# --- 1. Basic CPU / tool check -------------------------------------------

print_header "CPU and Intel Speed Select Capability"

if ! command -v intel-speed-select &>/dev/null; then
  echo "❌ intel-speed-select not found. Please install/build it first."
  exit 1
fi

command -v python3 >/dev/null 2>&1 || die "python3 not found"
command -v lscpu >/dev/null 2>&1 || die "lscpu not found"

$SUDO intel-speed-select --info 2>&1 | grep -E "Intel|Executing|Supported|Features" || true
echo

# --- 2. Check Turbo Frequency / PCT bucket capacity -----------------------

print_header "PCT Capacity from SST-TF bucket-${HP_BUCKET}"

TF_OUT="$($SUDO intel-speed-select turbo-freq info -l "$TDP_LEVEL" 2>&1 || true)"

if echo "$TF_OUT" | grep -qi "Invalid command: specify tdp_level"; then
  echo "⚠️  Multiple TDP levels detected. Set TDP_LEVEL and retry."
  echo "    Example: TDP_LEVEL=0 $0"
elif echo "$TF_OUT" | grep -qi "Failed to get turbo-freq info"; then
  echo "⚠️  turbo-freq info failed at TDP_LEVEL=${TDP_LEVEL}."
elif echo "$TF_OUT" | grep -qi "high-priority"; then
  echo "✅ PCT/SST-TF turbo tables detected."
else
  echo "⚠️  turbo-freq data not returned. PCT turbo tables may be unavailable or BIOS not configured."
fi

PCT_CAPACITY="$(detect_pct_capacity "$TDP_LEVEL" "$HP_BUCKET")"
echo "$PCT_CAPACITY"
eval "$PCT_CAPACITY"

THREADS_PER_CORE="$(get_threads_per_core)"

if [[ "${PCT_TOTAL_PHYSICAL_CORES:-0}" =~ ^[0-9]+$ ]]; then
  PCT_TOTAL_LOGICAL_CPUS=$(( PCT_TOTAL_PHYSICAL_CORES * THREADS_PER_CORE ))
else
  PCT_TOTAL_LOGICAL_CPUS=0
fi

echo "THREADS_PER_CORE=${THREADS_PER_CORE}"
echo "PCT_TOTAL_LOGICAL_CPUS=${PCT_TOTAL_LOGICAL_CPUS}"
echo

# --- 3. Check Core Power / CLOS status ------------------------------------

print_header "Core Power (CLOS) Feature Status"

CP_OUT="$($SUDO intel-speed-select core-power info 2>&1 || true)"

CORE_POWER_ENABLED=0
CLOS_ENABLED=0

if echo "$CP_OUT" | grep -q "support-status:supported"; then
  if echo "$CP_OUT" | grep -q "enable-status:enabled"; then
    CORE_POWER_ENABLED=1
    echo "✅ Core Power feature ENABLED"
  else
    echo "⚠️  Core Power supported but DISABLED in BIOS/runtime"
  fi

  if echo "$CP_OUT" | grep -q "clos-enable-status:enabled"; then
    CLOS_ENABLED=1
    echo "✅ CLOS ENABLED"
  else
    echo "⚠️  CLOS disabled"
  fi
else
  echo "❌ Core Power not supported on this system"
fi
echo

# --- 4. Enumerate CPU -> CLOS mapping -------------------------------------

print_header "CPU -> CLOS Mapping via get-assoc"

MAX_CPU="$(lscpu -p=CPU | grep -v '^#' | cut -d, -f1 | sort -n | tail -n 1 || true)"
if [[ -z "${MAX_CPU:-}" ]]; then
  echo "❌ Could not determine CPU range from lscpu."
  exit 1
fi

if ! $SUDO intel-speed-select -c 0 core-power get-assoc >/dev/null 2>&1; then
  echo "❌ This intel-speed-select build does not support: core-power get-assoc"
  exit 1
fi

tmp_map="$(mktemp)"
trap 'rm -f "$tmp_map"' EXIT

start=0
while (( start <= MAX_CPU )); do
  end=$(( start + CHUNK - 1 ))
  if (( end > MAX_CPU )); then
    end="$MAX_CPU"
  fi
  range="${start}-${end}"
  get_assoc_for_cpulist "$range" >> "$tmp_map"
  start=$(( end + 1 ))
done

if [[ "$DEBUG_MAP" == "1" ]]; then
  echo "DEBUG_MAP=1: Showing first 40 tmp_map lines with invisible chars:"
  cat -A "$tmp_map" | head -n 40
  echo
fi

echo "CLOS distribution (count by clos id):"
python3 - <<'PY' "$tmp_map"
import re
import sys
path = sys.argv[1]
counts = {}
with open(path, 'r', errors='replace') as f:
    for line in f:
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        clos = re.sub(r'[^0-9]', '', parts[1])
        if not clos:
            continue
        counts[clos] = counts.get(clos, 0) + 1
for k in sorted(counts, key=lambda x: int(x)):
    print(f'  clos:{k} -> {counts[k]} CPUs')
PY
echo

# --- 5. Print target CLOS list and validate against PCT budget ------------

print_header "CPU list for TARGET_CLOS=${TARGET_CLOS}"

CLOS_LINE="$(
python3 - <<'PY' "$tmp_map" "$TARGET_CLOS"
import re
import sys
path = sys.argv[1]
target = str(sys.argv[2])
cpus = []
with open(path, 'r', errors='replace') as f:
    for line in f:
        parts = line.strip().split()
        if len(parts) < 2:
            continue
        cpu = re.sub(r'[^0-9]', '', parts[0])
        clos = re.sub(r'[^0-9]', '', parts[1])
        if not cpu or not clos:
            continue
        if clos == target:
            cpus.append(int(cpu))
cpus = sorted(set(cpus))
if not cpus:
    print(f'⚠️  No CPUs currently report clos:{target}.')
    raise SystemExit(0)
res = []
i = 0
while i < len(cpus):
    j = i
    while j + 1 < len(cpus) and cpus[j + 1] == cpus[j] + 1:
        j += 1
    res.append(str(cpus[i]) if i == j else f'{cpus[i]}-{cpus[j]}')
    i = j + 1
print(f"clos:{target} CPU list: {','.join(res)}")
PY
)"

echo "${CLOS_LINE}"

if [[ "${CLOS_LINE}" =~ ^clos:${TARGET_CLOS}[[:space:]]CPU[[:space:]]list:\ (.*)$ ]]; then
  CLOS_LIST="${BASH_REMATCH[1]}"
  OUT_FILE="${RESULTS_DIR}/clos${TARGET_CLOS}_cpulist.txt"
  echo "${CLOS_LIST}" > "${OUT_FILE}"
  echo "Wrote clos:${TARGET_CLOS} CPU list to ${OUT_FILE}"

  CLOS_CPU_COUNT="$(count_cpulist "$CLOS_LIST")"
  echo
  print_header "PCT Budget Validation for CLOS${TARGET_CLOS}"
  echo "CLOS${TARGET_CLOS} CPU count             : ${CLOS_CPU_COUNT}"
  echo "PCT bucket                        : ${PCT_BUCKET:-bucket-${HP_BUCKET}}"
  echo "PCT reporting anchors             : ${PCT_REPORTING_ANCHORS:-0}"
  echo "PCT active packages/sockets       : ${PCT_ACTIVE_PACKAGES:-0}"
  echo "PCT cores per package/socket      : ${PCT_CORES_PER_PACKAGE:-0}"
  echo "PCT physical core budget          : ${PCT_TOTAL_PHYSICAL_CORES:-0}"
  echo "PCT max frequency                 : ${PCT_MAX_FREQ_MHZ:-0} MHz"
  echo "Threads per core                  : ${THREADS_PER_CORE}"
  echo "Expected PCT logical CPU budget   : ${PCT_TOTAL_LOGICAL_CPUS}"

  if (( PCT_TOTAL_LOGICAL_CPUS == 0 )); then
    echo "⚠️  Could not validate CLOS${TARGET_CLOS} count because PCT logical budget is 0/unknown."
  elif (( CLOS_CPU_COUNT > PCT_TOTAL_LOGICAL_CPUS )); then
    echo "⚠️  CLOS${TARGET_CLOS} has more CPUs than the bucket-${HP_BUCKET} PCT logical budget."
    echo "   This may fall into a lower SST-TF TRL bucket instead of true PCT frequency."
  elif (( CLOS_CPU_COUNT == PCT_TOTAL_LOGICAL_CPUS )); then
    echo "✅ CLOS${TARGET_CLOS} CPU count exactly matches the bucket-${HP_BUCKET} PCT logical budget."
  else
    echo "✅ CLOS${TARGET_CLOS} CPU count is within the bucket-${HP_BUCKET} PCT logical budget."
    echo "   This is a subset of PCT-capable logical CPUs."
  fi

  if (( CORE_POWER_ENABLED == 0 || CLOS_ENABLED == 0 )); then
    echo
    echo "⚠️  CLOS assignments are visible, but Core Power/CLOS enforcement is not fully enabled."
    echo "   get-assoc can report mappings even when core-power info says disabled."
    echo "   For PCT enforcement, run the set flow or enable Core Power/CLOS before benchmarking."
  fi
else
  echo "WARNING: Did not write clos list file; unexpected output: ${CLOS_LINE}" >&2
fi

echo

# --- 6. Friendly summary ---------------------------------------------------

print_header "Summary"

if echo "$TF_OUT" | grep -qi "high-priority"; then
  echo "✅ PCT turbo tables detected"
else
  echo "⚠️  PCT turbo tables not confirmed via turbo-freq output"
fi

if [[ "${PCT_TOTAL_PHYSICAL_CORES:-0}" != "0" ]]; then
  echo "✅ PCT capacity detected: ${PCT_TOTAL_PHYSICAL_CORES} physical HP cores total, ${PCT_TOTAL_LOGICAL_CPUS} logical CPUs with HT=${THREADS_PER_CORE}"
  echo "   Count model: bucket-${HP_BUCKET} counted once per package/socket, not once per powerdomain anchor."
else
  echo "⚠️  PCT capacity not detected"
fi

if (( CORE_POWER_ENABLED == 1 )); then
  echo "✅ Core Power enabled"
else
  echo "❌ Core Power disabled"
fi

if (( CLOS_ENABLED == 1 )); then
  echo "✅ CLOS enabled"
else
  echo "❌ CLOS disabled"
fi

echo "Done."
