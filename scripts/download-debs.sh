#!/usr/bin/env bash
# Run on an internet-connected machine that matches the offline VM:
# same distro, version, and architecture (e.g. Ubuntu 22.04 amd64).
# Requires Docker's apt repository (see README.md).
#
# Dependencies that are already installed on THIS machine are not downloaded, so a
# bundle built on a busy workstation can be missing libraries the offline VM lacks.
# Two ways to get a complete bundle:
#   - run this on a freshly installed machine of the same release, or
#   - copy /var/lib/dpkg/status from the offline VM to this machine and run
#       OFFLINE_DPKG_STATUS=/path/to/status ./scripts/download-debs.sh
#     so apt resolves dependencies against what the offline VM really has.
#
# Anything already in packages/*.deb is deleted first, so old versions do not
# end up in the bundle next to new ones.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES="${ROOT}/packages"
OFFLINE_DPKG_STATUS="${OFFLINE_DPKG_STATUS:-}"

SUDO=()
if [[ "$(id -u)" -ne 0 ]]; then
  SUDO=(sudo)
fi

apt_opts=(-o "Dir::Cache::archives=${PACKAGES}" -o APT::Keep-Downloaded-Packages=true)
closure="host"
if [[ -n "${OFFLINE_DPKG_STATUS}" ]]; then
  if [[ ! -s "${OFFLINE_DPKG_STATUS}" ]]; then
    echo "OFFLINE_DPKG_STATUS=${OFFLINE_DPKG_STATUS} is not a readable, non-empty file." >&2
    exit 1
  fi
  OFFLINE_DPKG_STATUS="$(realpath "${OFFLINE_DPKG_STATUS}")"
  apt_opts+=(-o "Dir::State::status=${OFFLINE_DPKG_STATUS}")
  closure="offline-status"
fi

mkdir -p "${PACKAGES}"
"${SUDO[@]}" rm -f "${PACKAGES}"/*.deb

"${SUDO[@]}" apt-get update

if ! apt-cache show docker-ce >/dev/null 2>&1; then
  echo "docker-ce not available from apt. Add Docker's repository first (see README.md)." >&2
  exit 1
fi

# Download Docker Engine packages and their dependencies into PACKAGES.
"${SUDO[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install \
  --download-only \
  -y \
  "${apt_opts[@]}" \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# apt leaves a lock file and a partial/ dir behind and the files are owned by root
# (apt ran under sudo). Clean up and hand everything back to the invoking user.
"${SUDO[@]}" rm -rf "${PACKAGES}/lock" "${PACKAGES}/partial"
"${SUDO[@]}" chown -R "$(id -u):$(id -g)" "${PACKAGES}"

shopt -s nullglob
debs=( "${PACKAGES}"/*.deb )
if [[ ${#debs[@]} -eq 0 ]]; then
  echo "apt reported success but no .deb files were saved under ${PACKAGES}." >&2
  echo "Everything may already be installed here; use OFFLINE_DPKG_STATUS (see top of this script)." >&2
  exit 1
fi

# Integrity list and a record of what this bundle was built for. install-offline.sh
# checks both on the offline VM.
( cd "${PACKAGES}" && sha256sum -- *.deb > SHA256SUMS )

# shellcheck disable=SC1091
. /etc/os-release
docker_ver="$(dpkg-deb -f "$(ls "${PACKAGES}"/docker-ce_*.deb)" Version 2>/dev/null || echo unknown)"
cat > "${PACKAGES}/MANIFEST" <<MANIFEST
ID=${ID:-unknown}
VERSION_ID=${VERSION_ID:-unknown}
ARCH=$(dpkg --print-architecture)
CREATED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
DOCKER_CE_VERSION=${docker_ver}
DEPENDENCY_BASIS=${closure}
PACKAGE_COUNT=${#debs[@]}
MANIFEST

echo "Saved ${#debs[@]} packages under: ${PACKAGES}"
echo "Copy this repo (packages/, scripts/ and config/) to the offline host, then run install-offline.sh as root."
echo "Or run ./scripts/create-transfer-bundle.sh to pack it into one archive."
