#!/usr/bin/env bash
# Run on the offline VM as root (sudo). Installs from ./packages/*.deb
#
# Environment:
#   WITH_DEFAULT_DAEMON_JSON=0  do not write config/daemon.json to /etc/docker/daemon.json
#   SKIP_PLATFORM_CHECK=1       install even if the bundle was built for a different OS release/arch
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGES="${ROOT}/packages"
CONFIG_SRC="${ROOT}/config/daemon.json"
CONFIG_DST="/etc/docker/daemon.json"

WITH_DEFAULT_DAEMON_JSON="${WITH_DEFAULT_DAEMON_JSON:-1}"
SKIP_PLATFORM_CHECK="${SKIP_PLATFORM_CHECK:-0}"

die() { echo "ERROR: $*" >&2; exit 1; }

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

shopt -s nullglob
debs=( "${PACKAGES}"/*.deb )
if [[ ${#debs[@]} -eq 0 ]]; then
  die "No .deb files in ${PACKAGES}. On an online machine run scripts/download-debs.sh first."
fi

# Is this the OS the bundle was built for? download-debs.sh records it in MANIFEST.
manifest_value() { sed -n "s/^$1=//p" "${PACKAGES}/MANIFEST"; }
if [[ -f "${PACKAGES}/MANIFEST" ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  want_id="$(manifest_value ID)"
  want_ver="$(manifest_value VERSION_ID)"
  want_arch="$(manifest_value ARCH)"
  have_arch="$(dpkg --print-architecture)"
  if [[ "${want_id}" != "${ID:-}" || "${want_ver}" != "${VERSION_ID:-}" || "${want_arch}" != "${have_arch}" ]]; then
    msg="Bundle was built for ${want_id} ${want_ver} ${want_arch}, this host is ${ID:-?} ${VERSION_ID:-?} ${have_arch}."
    if [[ "${SKIP_PLATFORM_CHECK}" == "1" ]]; then
      echo "WARNING: ${msg} Continuing because SKIP_PLATFORM_CHECK=1."
    else
      die "${msg} Rebuild the bundle on a matching machine, or set SKIP_PLATFORM_CHECK=1."
    fi
  fi
else
  echo "WARNING: ${PACKAGES}/MANIFEST not found; cannot check the bundle matches this OS."
fi

# Catch a corrupted USB copy before apt fails halfway through.
if [[ -f "${PACKAGES}/SHA256SUMS" ]]; then
  echo "Verifying package checksums..."
  ( cd "${PACKAGES}" && sha256sum --check --quiet SHA256SUMS ) \
    || die "Checksum mismatch in ${PACKAGES}. Copy the bundle again."
else
  echo "WARNING: ${PACKAGES}/SHA256SUMS not found; skipping integrity check."
fi

have_systemd=0
[[ -d /run/systemd/system ]] && have_systemd=1

was_active=0
if [[ "${have_systemd}" == "1" ]] && systemctl is-active --quiet docker 2>/dev/null; then
  was_active=1
fi

# Install the bundled daemon.json with safe address pools, but never clobber an
# existing operator-managed config. Pools default outside 172.16.0.0/12 to avoid
# overlapping common corporate LAN/VPN ranges (which would otherwise hijack
# return traffic via the docker0 / br-* routes).
#
# This must happen BEFORE the packages are installed: docker-ce's postinst starts
# dockerd, and a daemon that is already running keeps the default 172.17.0.0/16
# pools until it is restarted.
wrote_config=0
if [[ "${WITH_DEFAULT_DAEMON_JSON}" == "1" ]]; then
  if [[ ! -f "${CONFIG_SRC}" ]]; then
    echo "WARNING: ${CONFIG_SRC} is missing (was config/ copied?); Docker will use its stock address pools."
  elif [[ -e "${CONFIG_DST}" ]]; then
    echo "Existing ${CONFIG_DST} detected; leaving it untouched."
    echo "Reference defaults are in ${CONFIG_SRC} if you want to compare."
  else
    install -d -m 0755 /etc/docker
    install -m 0644 "${CONFIG_SRC}" "${CONFIG_DST}"
    wrote_config=1
    echo "Wrote ${CONFIG_DST} (safe Docker address pools outside 172.16.0.0/12)."
  fi
fi

export DEBIAN_FRONTEND=noninteractive
# apt resolves local .deb dependency order; no docker-compose project required.
if ! apt-get install -y "${debs[@]}"; then
  echo "" >&2
  echo "apt could not install the bundle. 'unmet dependencies' usually means the bundle was built on a" >&2
  echo "machine that already had those libraries. Rebuild it with OFFLINE_DPKG_STATUS (see README.md)." >&2
  exit 1
fi

if [[ "${have_systemd}" == "1" ]]; then
  systemctl daemon-reload
  systemctl enable --now docker
  if ! systemctl is-active --quiet docker; then
    echo "docker.service is not active. Check: journalctl -u docker --no-pager -n 50" >&2
    exit 1
  fi
  if [[ "${was_active}" == "1" && "${wrote_config}" == "1" ]]; then
    echo "NOTE: Docker was already running, so it is still on its old address pools."
    echo "      Restart it when containers can be interrupted: systemctl restart docker"
  fi
else
  echo "WARNING: systemd is not running here; start dockerd yourself (service docker start)."
fi

docker --version
echo "Docker installed. Add users with: usermod -aG docker <username>"
