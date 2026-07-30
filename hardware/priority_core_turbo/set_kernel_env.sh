#!/usr/bin/env bash

# Source this file before running docker compose build:
#   source ./set_kernel_env.sh
#
# This exports:
#   KERNEL_MM  - image tag suffix, for example 6.8
#   KERNEL_TAG - Linux kernel git tag, for example v6.8

kernel_release="$(uname -r)"
kernel_mm="$(printf '%s\n' "${kernel_release}" | awk -F. '{print $1 "." $2}')"

if [[ ! "${kernel_mm}" =~ ^[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: failed to detect kernel major.minor from uname -r: ${kernel_release}" >&2
  return 1 2>/dev/null || exit 1
fi

export KERNEL_MM="${kernel_mm}"
export KERNEL_TAG="v${kernel_mm}"

echo "Exported KERNEL_MM=${KERNEL_MM}"
echo "Exported KERNEL_TAG=${KERNEL_TAG}"

if [[ "${KERNEL_MM}" != "6.8" ]]; then
  echo "WARN: validated GNR PCT flow expects KERNEL_MM=6.8 and KERNEL_TAG=v6.8." >&2
  echo "      Override manually if needed: export KERNEL_MM=6.8 KERNEL_TAG=v6.8" >&2
fi
