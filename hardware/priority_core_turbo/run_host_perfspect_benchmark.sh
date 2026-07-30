#!/usr/bin/env bash
set -euo pipefail

RESULTS_DIR="${RESULTS_DIR:-results}"
CLOS_ID="${CLOS_ID:-0}"
CLOS_CPU_FILE="${CLOS_CPU_FILE:-${RESULTS_DIR}/clos${CLOS_ID}_cpulist.txt}"
PERFSPECT_ARGS="${PERFSPECT_ARGS:---speed --frequency --no-summary}"

if ! command -v perfspect >/dev/null 2>&1; then
  echo "ERROR: perfspect not found on host PATH."
  echo "Install PerfSpect on the host first, then rerun this script."
  exit 1
fi

if [[ ! -f "${CLOS_CPU_FILE}" ]]; then
  echo "ERROR: ${CLOS_CPU_FILE} not found."
  echo "Run the check profile first:"
  echo "  docker compose --progress=plain --profile check up --abort-on-container-exit"
  exit 1
fi

CLOS_CPUS="$(tr -d '[:space:]' < "${CLOS_CPU_FILE}")"

if [[ -z "${CLOS_CPUS}" ]]; then
  echo "ERROR: empty CLOS CPU list from ${CLOS_CPU_FILE}"
  exit 1
fi

OUT_DIR="${RESULTS_DIR}/perfspect_host_clos${CLOS_ID}_$(date +%Y%m%d_%H%M%S)"
PERFSPECT_OUTPUT="${OUT_DIR}/perfspect"
mkdir -p "${OUT_DIR}"

echo "------------------------------------------------------------"
echo "Host PerfSpect benchmark on CLOS${CLOS_ID} CPUs"
echo "------------------------------------------------------------"
echo "CLOS_ID=${CLOS_ID}"
echo "CLOS_CPU_FILE=${CLOS_CPU_FILE}"
echo "CLOS_CPUS=${CLOS_CPUS}"
echo "PERFSPECT_ARGS=${PERFSPECT_ARGS}"
echo "OUT_DIR=${OUT_DIR}"
echo

echo "${CLOS_CPUS}" > "${OUT_DIR}/clos${CLOS_ID}_cpulist.txt"

echo "Command:"
echo "sudo taskset -c ${CLOS_CPUS} perfspect benchmark ${PERFSPECT_ARGS} --output ${PERFSPECT_OUTPUT}"
echo

set +e
sudo taskset -c "${CLOS_CPUS}" perfspect benchmark ${PERFSPECT_ARGS} \
  --output "${PERFSPECT_OUTPUT}" \
  2>&1 | tee "${OUT_DIR}/perfspect_benchmark.log"
RC=${PIPESTATUS[0]}
set -e

echo
echo "------------------------------------------------------------"
echo "Host PerfSpect benchmark completed"
echo "------------------------------------------------------------"
echo "Exit code: ${RC}"
echo "Output dir: ${OUT_DIR}"

exit "${RC}"
