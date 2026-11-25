#!/usr/bin/env bash
# One-shot: remove conflicting Docker apt entries/keys, then add Docker's repo (Ubuntu DEB822).
# Run before download-debs.sh. Requires root and network. Ubuntu only.
set -euo pipefail

# Docker's published apt signing key (https://docs.docker.com/engine/install/ubuntu/).
DOCKER_KEY_FPR="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
KEY_URL="https://download.docker.com/linux/ubuntu/gpg"
KEYRING="/etc/apt/keyrings/docker.asc"
SOURCES="/etc/apt/sources.list.d/docker.sources"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
  echo "This script only supports Ubuntu (found ID=${ID:-unknown})." >&2
  echo "For other distros follow https://docs.docker.com/engine/install/ and then run download-debs.sh." >&2
  exit 1
fi
SUITE="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
if [[ -z "${SUITE}" ]]; then
  echo "Could not determine the Ubuntu release codename from /etc/os-release." >&2
  exit 1
fi

# Fetch and check the key first, so a network failure leaves the existing repo config alone.
tmp_key="$(mktemp)"
trap 'rm -f "${tmp_key}"' EXIT
curl -fsSL "${KEY_URL}" -o "${tmp_key}"

if command -v gpg >/dev/null 2>&1; then
  got="$(gpg --batch --show-keys --with-colons "${tmp_key}" | awk -F: '$1 == "fpr" {print $10; exit}')"
  if [[ "${got}" != "${DOCKER_KEY_FPR}" ]]; then
    echo "Docker GPG key fingerprint mismatch: got '${got}', expected ${DOCKER_KEY_FPR}." >&2
    exit 1
  fi
elif [[ "${SKIP_KEY_FINGERPRINT_CHECK:-0}" != "1" ]]; then
  echo "gpg is not installed, so the Docker key fingerprint cannot be checked." >&2
  echo "Install gnupg, or set SKIP_KEY_FINGERPRINT_CHECK=1 to continue without the check." >&2
  exit 1
fi

# Drop every Docker apt definition so Signed-By cannot conflict (e.g. .gpg vs .asc).
rm -f /etc/apt/sources.list.d/docker.list \
      /etc/apt/sources.list.d/docker.list.save \
      "${SOURCES}" \
      "${KEYRING}" \
      /etc/apt/keyrings/docker.gpg

install -m 0755 -d /etc/apt/keyrings
install -m 0644 "${tmp_key}" "${KEYRING}"

cat > "${SOURCES}" <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${SUITE}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: ${KEYRING}
EOF

apt-get update -qq
echo "Docker apt repo ready (${SUITE}). Run: ./scripts/download-debs.sh"
