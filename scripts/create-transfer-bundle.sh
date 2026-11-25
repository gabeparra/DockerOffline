#!/usr/bin/env bash
# Build a single tarball of scripts + downloaded packages for USB/sneakernet transfer.
# The archive unpacks into one docker-offline/ directory and gets a .sha256 file next to it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAMP="$(date -u +%Y%m%d-%H%M%S)"
OUT="${ROOT}/dist/docker-offline-bundle-${STAMP}.tar.gz"
mkdir -p "$(dirname "${OUT}")"

shopt -s nullglob
debs=( "${ROOT}/packages"/*.deb )
if [[ ${#debs[@]} -eq 0 ]]; then
  echo "No packages under packages/. Run download-debs.sh first." >&2
  exit 1
fi
for f in packages/SHA256SUMS packages/MANIFEST; do
  if [[ ! -f "${ROOT}/${f}" ]]; then
    echo "Missing ${f}. Re-run download-debs.sh (it writes the manifest and checksums)." >&2
    exit 1
  fi
done

# Only the .debs and their manifest: apt's lock file and partial/ dir stay out.
# (Paths are made relative to ROOT because tar runs with -C, but the glob above did not.)
tar -C "${ROOT}" -czf "${OUT}" \
  --transform 's,^,docker-offline/,' \
  "${debs[@]#"${ROOT}/"}" \
  packages/SHA256SUMS \
  packages/MANIFEST \
  scripts \
  config \
  README.md

( cd "$(dirname "${OUT}")" && sha256sum "$(basename "${OUT}")" > "$(basename "${OUT}").sha256" )

echo "Wrote: ${OUT}"
echo "Wrote: ${OUT}.sha256"
echo "On the offline VM: sha256sum -c $(basename "${OUT}").sha256 && tar -xzf $(basename "${OUT}") && sudo ./docker-offline/scripts/install-offline.sh"
