# Offline Docker Engine install bundle

Scripts that download Docker Engine and every dependency as `.deb` files on a connected machine, pack them into one archive, and install them on an air-gapped Ubuntu host with no network at all. The install also drops in a daemon config that keeps Docker's networks out of `172.16.0.0/12`.

**Status:** `Maintained` - tested on Ubuntu 24.04 amd64 with Docker Engine 29.10.1.

**Scope:** Ubuntu only (apt, Docker's Ubuntu repository). Tested on Ubuntu 24.04 amd64 with Docker Engine 29.10.1 (see [Testing](#testing)). Other Ubuntu releases should work but are not tested; other distros are not supported by these scripts.

System-wide install (not under a single user's home): packages place binaries under `/usr`, config under `/etc`, data under `/var/lib/docker` by default.

## Quickstart

### 1. Online machine (same Ubuntu release and architecture as the offline VM)

1. Add Docker's apt repository (official steps: [Install Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)). The bundled script does the same and also clears old `docker.list` + `docker.gpg` entries that conflict with `docker.sources` + `docker.asc`. It checks the key's fingerprint, so it needs `gnupg` installed:

   ```bash
   sudo ./scripts/setup-docker-apt-repo.sh
   ```

2. From this repo:

   ```bash
   ./scripts/download-debs.sh
   ```

   `.deb` files land in `packages/` (gitignored), together with `SHA256SUMS` and a `MANIFEST` recording the OS release and architecture. Old `.deb` files in `packages/` are deleted first.

   **Dependencies already installed on this machine are not downloaded.** If the offline VM lacks one of them, `install-offline.sh` fails with "unmet dependencies". Build the bundle against what the offline VM really has: copy `/var/lib/dpkg/status` from the offline VM to this machine and run

   ```bash
   OFFLINE_DPKG_STATUS=/path/to/status ./scripts/download-debs.sh
   ```

   Without that variable, run the download on a freshly installed machine of the same release.

3. Optional: ship everything as one archive. It unpacks into a `docker-offline/` directory and comes with a `.sha256` file:

   ```bash
   ./scripts/create-transfer-bundle.sh
   ```

### 2. Offline VM

Copy this repo (`packages/`, `scripts/` and `config/`) to the offline VM, or extract the transfer tarball:

```bash
sha256sum -c docker-offline-bundle-*.tar.gz.sha256
tar -xzf docker-offline-bundle-*.tar.gz
sudo ./docker-offline/scripts/install-offline.sh
```

The installer refuses a bundle built for a different Ubuntu release or architecture (override with `SKIP_PLATFORM_CHECK=1`), verifies `packages/SHA256SUMS`, writes the default `daemon.json` before installing so the first start already uses it, and exits non-zero if `docker.service` does not come up.

Remove `docker.io` or `podman-docker` first if they are installed; they conflict with `docker-ce`.

Grant Docker CLI access without sudo (members of the `docker` group effectively have root on the host):

```bash
sudo usermod -aG docker youruser
# log out and back in (or newgrp docker)
```

Check the install with `docker version` and `docker compose version`. There are no images on a fresh air-gapped host, so `docker run` has nothing to start until you load some (`docker load -i image.tar`).

## Default Docker address pools

`scripts/install-offline.sh` writes a minimal `/etc/docker/daemon.json` from `config/daemon.json` **only when no daemon.json already exists** (and warns if `config/` was not copied), configuring the daemon to allocate networks outside `172.16.0.0/12`:

- `docker0` (default bridge): `10.200.0.1/24`
- Default address pools for user-defined networks: `10.201.0.0/16` and `10.202.0.0/16`, `/24` per network (~512 networks total)

### Why

Stock Docker places `docker0` on `172.17.0.0/16` and hands out user-network subnets from `172.17.0.0/16` to `172.30.0.0/16`. On hosts whose LAN or VPN lives anywhere in `172.16.0.0/12` (common in enterprise networks), the `docker0` route becomes more specific than the upstream route and silently steals return traffic, breaking inbound connections (including SSH) from clients inside the overlapping range. Pinning pools outside `172.16.0.0/12` avoids the conflict.

### Customizing

Edit `/etc/docker/daemon.json` and restart Docker:

```bash
sudo systemctl restart docker
```

Validate the file first if you're unsure:

```bash
python3 -m json.tool /etc/docker/daemon.json
sudo dockerd --validate
```

Pre-existing user-defined networks keep their old subnets; recreate them (`docker compose down && docker compose up -d`, or `docker network rm`) to pick up the new pools.

### Skipping the default config

```bash
WITH_DEFAULT_DAEMON_JSON=0 sudo ./scripts/install-offline.sh
```

## Testing

`tests/e2e.sh` builds a bundle in an Ubuntu container, installs it in a second container with `--network none`, and checks that a corrupted package and a wrong-release bundle are rejected. It needs podman or docker and network access for the build step (about 150 MB). Set `UBUNTU_IMAGE=ubuntu:22.04` to try another release.

```bash
tests/e2e.sh
shellcheck -x scripts/*.sh tests/*.sh
```

The test containers do not run systemd, so starting `docker.service` and the address pools taking effect on a live daemon are not covered. Check those by hand on a real VM.

## Notes

- Download on a machine that matches the offline VM's Ubuntu release and architecture.
- To upgrade, build a new bundle and run `install-offline.sh` again. An existing `daemon.json` is never overwritten, and a running daemon is not restarted for you.
- To remove Docker: `sudo apt-get purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`. Images and volumes stay in `/var/lib/docker` until you delete them.

## Troubleshooting apt

**`E: Conflicting values set for option Signed-By ... docker.gpg != docker.asc`**: Two Docker repo definitions are active (often an old `docker.list` using `docker.gpg` plus a new `docker.sources` using `docker.asc`). Remove the duplicates or run `sudo ./scripts/setup-docker-apt-repo.sh`, which clears Docker's apt sources/key files and recreates a single `docker.sources`.

**`NO_PUBKEY ...` / repository is not signed**: Usually fixed after the conflict above; the key file must match `Signed-By` in the only remaining Docker source. Re-run `setup-docker-apt-repo.sh` if needed.

## Stack & Architecture

- **Stack:** Bash (`apt`, `dpkg`, `gnupg`, `sha256sum`), Ubuntu Docker Engine `.deb` packages, and container-based end-to-end verification (`podman` or `docker`).
- **Layout:** `scripts/` (repo setup, `.deb` downloader, bundle packer, offline installer), `config/daemon.json` (non-overlapping Docker address pools), `tests/e2e.sh` (air-gapped install tests), and `.github/workflows/lint.yml` (`shellcheck`).

## License

MIT - see [LICENSE](./LICENSE).
