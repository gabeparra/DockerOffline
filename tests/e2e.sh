#!/usr/bin/env bash
# End-to-end check: build a bundle in one Ubuntu container, then install it in a second
# container that has no network, and make sure bad bundles are rejected.
# Needs podman or docker plus network access for the build step (~150 MB download).
#
#   tests/e2e.sh                 # ubuntu:24.04
#   UBUNTU_IMAGE=ubuntu:22.04 tests/e2e.sh
# The bash -c bodies below are single-quoted on purpose: they expand inside the container.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${UBUNTU_IMAGE:-ubuntu:24.04}"

if command -v podman >/dev/null 2>&1; then RT=podman
elif command -v docker >/dev/null 2>&1; then RT=docker
else echo "need podman or docker" >&2; exit 2; fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/repo" "${WORK}/target"
# Copy the tree so the test never writes packages/ or dist/ into the checkout.
tar -C "${ROOT}" --exclude=.git --exclude=packages --exclude=dist -cf - . | tar -C "${WORK}/repo" -xf -

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
# --user 0 and :Z keep this working with rootless podman and SELinux.
run() { "${RT}" run --rm --user 0 "$@"; }

# What the offline VM looks like: a stock image. Its dpkg status is what the build resolves against.
run "${IMAGE}" cat /var/lib/dpkg/status > "${WORK}/offline-status"

echo "== build bundle (online container)"
run -v "${WORK}/repo:/work:Z" -v "${WORK}/offline-status:/offline-status:ro,Z" -w /work "${IMAGE}" bash -euc '
  apt-get update -qq >/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl ca-certificates sudo gnupg >/dev/null
  ./scripts/setup-docker-apt-repo.sh
  OFFLINE_DPKG_STATUS=/offline-status ./scripts/download-debs.sh
  ./scripts/create-transfer-bundle.sh
'
cp "${WORK}"/repo/dist/*.tar.gz "${WORK}"/repo/dist/*.tar.gz.sha256 "${WORK}/target/"
pass "bundle built"

echo "== install bundle (offline container, --network none)"
run --network none -v "${WORK}/target:/target:Z" -w /target "${IMAGE}" bash -euc '
  sha256sum --check ./*.sha256
  tar -xzf ./*.tar.gz
  ./docker-offline/scripts/install-offline.sh
  docker --version
  docker compose version
  cmp /etc/docker/daemon.json docker-offline/config/daemon.json
  dockerd --validate --config-file /etc/docker/daemon.json
'
pass "offline install, daemon.json in place and valid"

echo "== a corrupted package is rejected"
run --network none -v "${WORK}/target:/target:Z" -w /target "${IMAGE}" bash -uc '
  tar -xzf ./*.tar.gz
  f="$(ls docker-offline/packages/docker-ce-cli_*.deb)"
  printf x >> "${f}"
  if ./docker-offline/scripts/install-offline.sh; then echo "install should have failed"; exit 1; fi
  command -v docker >/dev/null && { echo "docker was installed anyway"; exit 1; }
  exit 0
' || fail "corrupted bundle was not rejected"
pass "corrupted package rejected before apt ran"

echo "== a bundle for another release is rejected"
run --network none -v "${WORK}/target:/target:Z" -w /target "${IMAGE}" bash -uc '
  tar -xzf ./*.tar.gz
  sed -i "s/^VERSION_ID=.*/VERSION_ID=1.00/" docker-offline/packages/MANIFEST
  if ./docker-offline/scripts/install-offline.sh; then echo "install should have failed"; exit 1; fi
  command -v docker >/dev/null && { echo "docker was installed anyway"; exit 1; }
  exit 0
' || fail "wrong-platform bundle was not rejected"
pass "wrong-platform bundle rejected"

echo "All end-to-end checks passed."
