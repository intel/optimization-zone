#!/usr/bin/env bash
# pct_map_and_set_clos.sh
#
# SET mode (default):
#   - Detect PCT capacity from `intel-speed-select turbo-freq info -l <TDP_LEVEL>`.
#   - Treat bucket-0 as the PCT bucket by default.
#   - Count PCT capacity ONCE PER PACKAGE/SOCKET, not once per powerdomain anchor.
#   - Dispatch the package-level PCT physical-core budget across that package's
#     PCT reporting powerdomain anchors.
#   - Select contiguous physical CPUs starting from each reporting anchor CPU.
#   - Include Hyper-Threading siblings by default.
#   - Overwrite existing BIOS/runtime CLOS assignment:
#       1. all online CPUs -> OTHER_CLOS
#       2. selected HP CPUs -> HP_CLOS
#
# Example on a 2-socket system:
#   bucket-0 reports 8 PCT physical cores per package.
#   turbo-freq output has 2 reporting anchors per package:
#       package 0: cpu0, cpu32
#       package 1: cpu64, cpu96
#   Default dispatch:
#       package 0: 4 physical cores from cpu0 + 4 from cpu32
#       package 1: 4 physical cores from cpu64 + 4 from cpu96
#   With INCLUDE_HT=1:
#       HP effective: 0-3,32-35,64-67,96-99,128-131,160-163,192-195,224-227
#
# UNSET mode:
#   - Set ALL CPUs -> OTHER_CLOS
#   - Disable core-power / CLOS best-effort across intel-speed-select builds
#
set -euo pipefail

ACTION="${ACTION:-set}"               # set | unset
HP_BUCKET="${HP_BUCKET:-0}"
TDP_LEVEL="${TDP_LEVEL:-1}"

# Optional override. If unset/0, use bucket-0 cores per package from SST-TF.
# HP_PER_DOMAIN is accepted as a backward-compatible alias, but is interpreted
# as per-package budget, not per-domain budget.
HP_PER_PACKAGE="${HP_PER_PACKAGE:-${HP_PER_DOMAIN:-}}"

INCLUDE_HT="${INCLUDE_HT:-1}"
HP_CLOS="${HP_CLOS:-0}"
OTHER_CLOS="${OTHER_CLOS:-2}"

DEBUG_MODE="${DEBUG_MODE:-0}"
DRY_RUN="${DRY_RUN:-0}"
DEBUG_VERBOSE="${DEBUG_VERBOSE:-0}"
DEBUG_MAP="${DEBUG_MAP:-0}"
SHOW_VERIFY_LINES="${SHOW_VERIFY_LINES:-40}"

SUDO=""
[[ "$(id -u)" -ne 0 ]] && SUDO="sudo"
ISS="${ISS:-$SUDO intel-speed-select}"

print_header() {
  echo "------------------------------------------------------------"
  echo "$1"
  echo "------------------------------------------------------------"
}

die() { echo "ERROR: $*" >&2; exit 1; }

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

build_non_hp_ranges() {
  local hp_list="$1"
  local all_cpus="$2"
  HP_LIST="$hp_list" ALL_CPUS="$all_cpus" python3 - <<'PY'
import os
hp = os.environ['HP_LIST']
all_ = os.environ['ALL_CPUS']

def expand(s):
    out = set()
    for part in s.split(','):
        part = part.strip()
        if not part:
            continue
        if '-' in part:
            a, b = part.split('-', 1)
            out.update(range(int(a), int(b) + 1))
        else:
            out.add(int(part))
    return out

hp_set = expand(hp)
all_set = expand(all_)
non = sorted(all_set - hp_set)
res = []
i = 0
while i < len(non):
    j = i
    while j + 1 < len(non) and non[j + 1] == non[j] + 1:
        j += 1
    res.append(str(non[i]) if i == j else f"{non[i]}-{non[j]}")
    i = j + 1
print(','.join(res))
PY
}

detect_pct_capacity() {
  local tdp_level="${1:-1}"
  local bucket="${2:-0}"
  local out

  out="$($ISS turbo-freq info -l "$tdp_level" 2>&1 || true)"

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
import os, re, sys
from collections import defaultdict

want_bucket = f"bucket-{sys.argv[1]}"
lines = os.environ.get('PCT_TF_OUT', '').splitlines()
anchors = []
cur_pkg = cur_die = cur_pd = cur_cpu = cur_bucket = None

for line in lines:
    s = line.strip()
    m = re.match(r'package-(\d+)', s)
    if m:
        cur_pkg = int(m.group(1)); continue
    m = re.match(r'die-(\d+)', s)
    if m:
        cur_die = int(m.group(1)); continue
    m = re.match(r'powerdomain-(\d+)', s)
    if m:
        cur_pd = int(m.group(1)); cur_cpu = None; continue
    if s == 'cpu-None':
        cur_cpu = None; continue
    m = re.match(r'cpu-(\d+)', s)
    if m:
        cur_cpu = int(m.group(1)); continue
    m = re.match(r'bucket-(\d+)', s)
    if m:
        cur_bucket = f"bucket-{m.group(1)}"; continue

    if cur_bucket == want_bucket and 'high-priority-cores-count:' in s:
        count = int(re.sub(r'.*high-priority-cores-count:\s*', '', s).split()[0])
        anchors.append({'package': cur_pkg, 'die': cur_die, 'powerdomain': cur_pd,
                        'cpu': cur_cpu, 'count': count, 'freq': None})
        continue

    if cur_bucket == want_bucket and 'high-priority-max-level-0-frequency(MHz):' in s:
        freq = int(re.sub(r'.*frequency\(MHz\):\s*', '', s).split()[0])
        if anchors:
            anchors[-1]['freq'] = freq
        continue

active = [d for d in anchors if d['cpu'] is not None]
if not active:
    print(f'PCT_BUCKET={want_bucket}')
    print('PCT_REPORTING_ANCHORS=0')
    print('PCT_ACTIVE_PACKAGES=0')
    print('PCT_CORES_PER_PACKAGE=0')
    print('PCT_TOTAL_PHYSICAL_CORES=0')
    print('PCT_MAX_FREQ_MHZ=0')
    print('PCT_DOMAIN_ANCHORS=')
    print('PCT_PACKAGE_SUMMARY=')
    raise SystemExit(0)

by_pkg = defaultdict(list)
for d in active:
    by_pkg[d['package']].append(d)

pkg_counts = {}
pkg_freqs = {}
for pkg, ds in sorted(by_pkg.items()):
    counts = sorted(set(d['count'] for d in ds))
    freqs = sorted(set(d['freq'] for d in ds if d['freq'] is not None))
    pkg_counts[pkg] = min(counts) if counts else 0
    pkg_freqs[pkg] = max(freqs) if freqs else None

all_counts = sorted(set(pkg_counts.values()))
all_freqs = sorted(set(v for v in pkg_freqs.values() if v is not None))
domain_anchors = ','.join(
    f"pkg{d['package']}/die{d['die']}/pd{d['powerdomain']}/cpu{d['cpu']}:cores{d['count']}:freq{d['freq']}"
    for d in active
)
package_summary = ','.join(
    f"pkg{pkg}:cores{pkg_counts[pkg]}:freq{pkg_freqs[pkg]}:anchors{len(by_pkg[pkg])}"
    for pkg in sorted(pkg_counts)
)

print(f'PCT_BUCKET={want_bucket}')
print(f'PCT_REPORTING_ANCHORS={len(active)}')
print(f'PCT_ACTIVE_PACKAGES={len(pkg_counts)}')
print(f"PCT_CORES_PER_PACKAGE={','.join(map(str, all_counts))}")
print(f'PCT_TOTAL_PHYSICAL_CORES={sum(pkg_counts.values())}')
print(f"PCT_MAX_FREQ_MHZ={','.join(map(str, all_freqs)) if all_freqs else 'unknown'}")
print(f'PCT_DOMAIN_ANCHORS={domain_anchors}')
print(f'PCT_PACKAGE_SUMMARY={package_summary}')
PY
}

select_hp_cpus_by_powerdomain_anchors() {
  local hp_per_package="$1"
  local include_ht="$2"
  local domain_anchors="$3"

  [[ "$hp_per_package" =~ ^[0-9]+$ ]] || die "HP_PER_PACKAGE must be numeric, got '$hp_per_package'"
  (( hp_per_package > 0 )) || die "HP_PER_PACKAGE must be > 0"
  [[ -n "$domain_anchors" ]] || die "PCT_DOMAIN_ANCHORS is empty"

  LSC_CPU_TOPO="$(lscpu -p=CPU,SOCKET,CORE 2>/dev/null | grep -v '^#' || true)"
  [[ -n "$LSC_CPU_TOPO" ]] || die "Could not read lscpu -p=CPU,SOCKET,CORE"

  LSC_CPU_TOPO="$LSC_CPU_TOPO" \
  HP_PER_PACKAGE="$hp_per_package" \
  INCLUDE_HT="$include_ht" \
  PCT_DOMAIN_ANCHORS="$domain_anchors" \
  python3 - <<'PY'
import os, re
from collections import defaultdict

topo = os.environ['LSC_CPU_TOPO'].splitlines()
hp_per_package = int(os.environ['HP_PER_PACKAGE'])
include_ht = os.environ['INCLUDE_HT'] == '1'
anchors_text = os.environ['PCT_DOMAIN_ANCHORS'].strip()

logical_by_socket_core = defaultdict(list)
for line in topo:
    line = line.strip()
    if not line:
        continue
    parts = line.split(',')
    if len(parts) < 3:
        continue
    cpu, socket, core = map(int, parts[:3])
    logical_by_socket_core[(socket, core)].append(cpu)

ordered_cores = defaultdict(list)
for (socket, core), cpus in logical_by_socket_core.items():
    cpus = sorted(cpus)
    ordered_cores[socket].append((cpus[0], core, cpus))
for socket in ordered_cores:
    ordered_cores[socket].sort(key=lambda x: x[0])

anchors_by_pkg = defaultdict(list)
for rec in anchors_text.split(','):
    rec = rec.strip()
    if not rec:
        continue
    m = re.match(r'pkg(\d+)/die(\d+)/pd(\d+)/cpu(\d+):cores(\d+):freq([^,]+)', rec)
    if not m:
        continue
    pkg = int(m.group(1))
    die = int(m.group(2))
    pd = int(m.group(3))
    anchor_cpu = int(m.group(4))
    reported_count = int(m.group(5))
    freq = m.group(6)

    # On this platform package id maps to socket id. If not, fall back by locating anchor_cpu.
    socket = pkg
    found = False
    for s, items in ordered_cores.items():
        for _, core, logicals in items:
            if anchor_cpu in logicals:
                socket = s
                found = True
                break
        if found:
            break
    if not found:
        raise SystemExit(f'ERROR: anchor cpu{anchor_cpu} not found in lscpu topology')

    anchors_by_pkg[pkg].append({
        'pkg': pkg, 'socket': socket, 'die': die, 'pd': pd,
        'anchor_cpu': anchor_cpu, 'reported_count': reported_count, 'freq': freq,
    })

if not anchors_by_pkg:
    raise SystemExit('ERROR: no PCT reporting anchors parsed')

selected = []
for pkg in sorted(anchors_by_pkg):
    anchors = sorted(anchors_by_pkg[pkg], key=lambda a: a['anchor_cpu'])
    n = len(anchors)
    base = hp_per_package // n
    rem = hp_per_package % n
    per_anchor = [base + (1 if i < rem else 0) for i in range(n)]

    print(f'package {pkg}: HP_PER_PACKAGE={hp_per_package}, reporting_anchors={n}, dispatch_per_anchor={per_anchor}')

    for idx, anchor in enumerate(anchors):
        take = per_anchor[idx]
        if take == 0:
            continue
        socket = anchor['socket']
        anchor_cpu = anchor['anchor_cpu']
        items = ordered_cores[socket]

        pos = None
        for i, (first_cpu, core, logicals) in enumerate(items):
            if first_cpu == anchor_cpu or anchor_cpu in logicals:
                pos = i
                break
        if pos is None:
            raise SystemExit(f'ERROR: could not locate anchor cpu{anchor_cpu} in socket {socket}')
        if pos + take > len(items):
            raise SystemExit(
                f'ERROR: anchor cpu{anchor_cpu} in socket {socket} requested {take} cores, '
                f'but only {len(items)-pos} physical cores remain from that anchor'
            )

        chosen = items[pos:pos + take]
        desc = []
        chosen_cpus = []
        for _, core, logicals in chosen:
            use = logicals if include_ht else logicals[:1]
            chosen_cpus.extend(use)
            desc.append(f'core{core}:' + '/'.join(map(str, use)))
        print(f"  pkg{pkg}/pd{anchor['pd']}/anchor_cpu{anchor_cpu} -> {take} physical cores -> " + ' '.join(desc))
        selected.extend(chosen_cpus)

xs = sorted(set(selected))
if not xs:
    raise SystemExit('ERROR: selected HP CPU list is empty')
res = []
i = 0
while i < len(xs):
    j = i
    while j + 1 < len(xs) and xs[j + 1] == xs[j] + 1:
        j += 1
    res.append(str(xs[i]) if i == j else f'{xs[i]}-{xs[j]}')
    i = j + 1
print('HP_EFFECTIVE=' + ','.join(res))
PY
}

enable_clos_or_die() {
  local ok=0
  local cmd
  for cmd in \
    "$ISS core-power enable --priority 1" \
    "$ISS core-power enable --clos" \
    "$ISS core-power enable"
  do
    [[ "$DEBUG_VERBOSE" == "1" ]] && echo "Trying: $cmd"
    if eval "$cmd" >/dev/null 2>&1; then
      ok=1
      [[ "$DEBUG_VERBOSE" == "1" ]] && echo "OK: $cmd"
      break
    fi
  done
  (( ok == 1 )) || die "Could not enable core-power/CLOS with this intel-speed-select build"
}

disable_core_power_best_effort() {
  local ok=0
  local cmd
  for cmd in \
    "$ISS core-power disable --clos" \
    "$ISS core-power disable"
  do
    [[ "$DEBUG_VERBOSE" == "1" ]] && echo "Trying: $cmd"
    if eval "$cmd" >/dev/null 2>&1; then
      ok=1
      [[ "$DEBUG_VERBOSE" == "1" ]] && echo "OK: $cmd"
      break
    fi
  done
  if [[ "$ok" -ne 1 ]]; then
    echo "WARN: Could not disable core-power via intel-speed-select on this build." >&2
    echo "      You can still consider PCT 'unset' because all CPUs were moved to CLOS${OTHER_CLOS}." >&2
  fi
}

apply_assoc_quiet_or_die() {
  local cpu_list="$1"
  local clos="$2"
  [[ -n "$cpu_list" ]] || die "apply_assoc got empty cpu_list (clos=$clos)"
  [[ "$clos" =~ ^[0-9]+$ ]] || die "apply_assoc got non-numeric clos='$clos'"

  if [[ "$DEBUG_VERBOSE" == "1" ]]; then
    $ISS -c "$cpu_list" core-power assoc --clos "$clos"
    return 0
  fi

  local out rc=0
  out="$($ISS -c "$cpu_list" core-power assoc --clos "$clos" 2>&1 >/dev/null)" || rc=$?
  if (( rc != 0 )) || echo "$out" | grep -qiE 'malformed arguments|Error:'; then
    echo "$out" >&2
    die "intel-speed-select assoc failed (clos=$clos cpu_list=$cpu_list)"
  fi
}

get_assoc_pairs() {
  local cpu_list="$1"
  [[ -n "$cpu_list" ]] || return 0
  $ISS -c "$cpu_list" core-power get-assoc 2>&1 | awk '
    /cpu-[0-9]+/{
      cpu=$0; sub(/^.*cpu-/,"",cpu); sub(/[^0-9].*$/, "", cpu); next
    }
    /clos:[0-9]+/{
      clos=$0; sub(/^.*clos:/,"",clos); sub(/[^0-9].*$/, "", clos);
      if (cpu!="") printf "cpu-%s clos:%s\n", cpu, clos
    }'
}

command -v lscpu >/dev/null 2>&1 || die "lscpu not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found"
command -v intel-speed-select >/dev/null 2>&1 || die "intel-speed-select not found"

ALL_CPUS_CSV="$(lscpu -p=CPU | grep -v '^#' | cut -d, -f1 | sort -n | uniq | paste -sd, -)"
[[ -n "$ALL_CPUS_CSV" ]] || die "Could not enumerate online CPUs"

if [[ "$ACTION" == "unset" ]]; then
  print_header "UNSET: move all CPUs to OTHER_CLOS and disable core-power"
  echo "OTHER_CLOS=$OTHER_CLOS"
  echo

  if [[ "$DEBUG_MODE" == "1" || "$DRY_RUN" == "1" ]]; then
    print_header "READ-ONLY / DRY-RUN"
    echo "Would run:"
    echo "  $ISS core-power enable --priority 1   (or compatible fallback)"
    echo "  $ISS -c \"$ALL_CPUS_CSV\" core-power assoc --clos $OTHER_CLOS"
    echo "  $ISS core-power disable --clos   (or disable)"
    exit 0
  fi

  enable_clos_or_die
  apply_assoc_quiet_or_die "$ALL_CPUS_CSV" "$OTHER_CLOS"
  disable_core_power_best_effort

  echo
  print_header "Verification (sample CPU->CLOS after UNSET)"
  get_assoc_pairs "$ALL_CPUS_CSV" | head -n "$SHOW_VERIFY_LINES" || true
  echo "… (showing first $SHOW_VERIFY_LINES lines)"
  echo
  echo "Done."
  exit 0
fi

[[ "$ACTION" == "set" ]] || die "Unknown ACTION='$ACTION' (use set|unset)"

print_header "PCT capacity from SST-TF bucket-${HP_BUCKET}"
PCT_CAPACITY="$(detect_pct_capacity "$TDP_LEVEL" "$HP_BUCKET")"
echo "$PCT_CAPACITY"
eval "$PCT_CAPACITY"
echo

if [[ "${PCT_TOTAL_PHYSICAL_CORES:-0}" == "0" ]]; then
  die "Could not detect PCT capacity from turbo-freq bucket-${HP_BUCKET}"
fi

if [[ -z "${HP_PER_PACKAGE}" || "${HP_PER_PACKAGE}" == "0" ]]; then
  HP_PER_PACKAGE="$(echo "${PCT_CORES_PER_PACKAGE}" | awk -F, '{print $1}')"
fi
[[ "$HP_PER_PACKAGE" =~ ^[0-9]+$ ]] || die "Could not derive numeric HP_PER_PACKAGE from PCT_CORES_PER_PACKAGE=${PCT_CORES_PER_PACKAGE}"

print_header "Config"
echo "ACTION=$ACTION"
echo "HP_BUCKET=$HP_BUCKET  TDP_LEVEL=$TDP_LEVEL"
echo "HP_PER_PACKAGE=$HP_PER_PACKAGE"
echo "INCLUDE_HT=$INCLUDE_HT"
echo "HP_CLOS=$HP_CLOS  OTHER_CLOS=$OTHER_CLOS"
echo "DEBUG_MODE=$DEBUG_MODE  DRY_RUN=$DRY_RUN  DEBUG_VERBOSE=$DEBUG_VERBOSE  DEBUG_MAP=$DEBUG_MAP"
echo

print_header "Powerdomain-anchor HP CPU dispatch"
SELECTION_OUT="$(select_hp_cpus_by_powerdomain_anchors "$HP_PER_PACKAGE" "$INCLUDE_HT" "$PCT_DOMAIN_ANCHORS")"
echo "$SELECTION_OUT"
HP_EFFECTIVE="$(echo "$SELECTION_OUT" | awk -F= '/^HP_EFFECTIVE=/{print $2}' | tail -n1)"
[[ -n "$HP_EFFECTIVE" ]] || die "HP_EFFECTIVE is empty"

HP_EFFECTIVE_COUNT="$(count_cpulist "$HP_EFFECTIVE")"
NON_HP_RANGES="$(build_non_hp_ranges "$HP_EFFECTIVE" "$ALL_CPUS_CSV")"
[[ -n "$NON_HP_RANGES" ]] || die "NON_HP_RANGES is empty"

print_header "Computed CPU lists"
echo "HP effective      : $HP_EFFECTIVE"
echo "HP CPU count      : $HP_EFFECTIVE_COUNT"
echo "Non-HP            : $NON_HP_RANGES"
echo

echo "PCT active packages/sockets       : ${PCT_ACTIVE_PACKAGES:-0}"
echo "PCT reporting anchors             : ${PCT_REPORTING_ANCHORS:-0}"
echo "PCT cores per package/socket      : ${PCT_CORES_PER_PACKAGE:-0}"
echo "PCT physical core budget          : ${PCT_TOTAL_PHYSICAL_CORES:-0}"
echo "PCT max frequency                 : ${PCT_MAX_FREQ_MHZ:-0} MHz"
echo

if [[ "$INCLUDE_HT" == "1" ]]; then
  EXPECTED_HP_COUNT=$(( PCT_TOTAL_PHYSICAL_CORES * 2 ))
else
  EXPECTED_HP_COUNT=$(( PCT_TOTAL_PHYSICAL_CORES ))
fi

echo "Expected HP CPU count for this INCLUDE_HT setting: $EXPECTED_HP_COUNT"
if (( HP_EFFECTIVE_COUNT != EXPECTED_HP_COUNT )); then
  echo "WARN: HP CPU count ($HP_EFFECTIVE_COUNT) does not match expected count ($EXPECTED_HP_COUNT)." >&2
  echo "      Verify PCT_DOMAIN_ANCHORS, lscpu topology, and INCLUDE_HT before benchmarking." >&2
fi

echo

if [[ "$DEBUG_MODE" == "1" ]]; then
  print_header "DEBUG_MODE=1 (read-only)"
  echo "No CLOS changes applied. No verification performed."
  exit 0
fi

if [[ "$DRY_RUN" == "1" ]]; then
  print_header "DRY_RUN=1 (no changes)"
  echo "Would run:"
  echo "  $ISS core-power enable --priority 1   (or compatible fallback)"
  echo "  $ISS -c \"$ALL_CPUS_CSV\" core-power assoc --clos $OTHER_CLOS"
  echo "  $ISS -c \"$HP_EFFECTIVE\" core-power assoc --clos $HP_CLOS"
  exit 0
fi

print_header "Apply CLOS assignments (overwrite existing BIOS/runtime mapping)"
echo "Setting ALL CPUs -> CLOS${OTHER_CLOS} first"
echo "Setting selected HP CPUs -> CLOS${HP_CLOS}"

enable_clos_or_die
apply_assoc_quiet_or_die "$ALL_CPUS_CSV" "$OTHER_CLOS"
apply_assoc_quiet_or_die "$HP_EFFECTIVE" "$HP_CLOS"

echo "Applied."
echo

print_header "Verification (concise CPU->CLOS)"
echo "HP list should be clos:$HP_CLOS"
get_assoc_pairs "$HP_EFFECTIVE" | head -n "$SHOW_VERIFY_LINES" || true
echo "… (showing first $SHOW_VERIFY_LINES lines)"
echo

echo "Non-HP list should be clos:$OTHER_CLOS"
get_assoc_pairs "$NON_HP_RANGES" | head -n "$SHOW_VERIFY_LINES" || true
echo "… (showing first $SHOW_VERIFY_LINES lines)"
echo

echo "Done."
