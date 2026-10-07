# Prerequisites

Everything is compiled inside Docker containers; the host only needs a few
tools. `make check` verifies all of them and prints install hints.

| Tool | Why | Install |
|---|---|---|
| Docker with the buildx plugin | builds OTP, Elixir, the release and the Asterinas kernel | macOS: `brew install colima docker docker-buildx`; Linux: docker-ce + `docker-buildx-plugin` |
| `qemu-system-x86_64` 8 or newer | boots the image | `brew install qemu` / `apt install qemu-system-x86` |
| GNU `make`, `python3`, `openssl`, `git`, `lsof` | build driver and smoke test clients | usually present |
| `timeout` (GNU coreutils) | smoke test | macOS: `brew install coreutils` |

## macOS (Apple Silicon)

Docker Desktop is not required. Colima works well:

```sh
brew install colima docker docker-buildx qemu coreutils
mkdir -p ~/.docker/cli-plugins
ln -sf "$(brew --prefix)/opt/docker-buildx/bin/docker-buildx" ~/.docker/cli-plugins/
colima start --cpu 8 --memory 12 --disk 80 --vm-type vz --vz-rosetta
make check
```

Give the VM at least 8 CPUs and 12 GB: the Asterinas kernel build and the
OTP build both like parallelism. The containers run natively on arm64; only
the final ERTS binaries are cross-compiled for x86-64, so there is no
emulation on the build path (see [Build pipeline](../internals/build.md)).

QEMU on macOS has no KVM. The image still boots, through TCG (software
emulation of x86-64). Expect 3 to 5 s to the IEx prompt and about 12 minutes
for the full `make smoke`.

## Linux (x86-64)

```sh
sudo apt install docker.io docker-buildx-plugin qemu-system-x86 make python3 openssl
sudo usermod -aG docker,kvm "$USER"   # re-login
make check
```

With a writable `/dev/kvm`, `make` selects KVM automatically and boots are
fast.

## Disk and network

The first build downloads the OTP, Elixir and Asterinas sources and the
Asterinas development container (about 4 GB). Budget 15 GB of Docker disk.
Build artefacts live under `build/` and are not committed.
