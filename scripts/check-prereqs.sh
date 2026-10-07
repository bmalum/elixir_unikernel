#!/usr/bin/env bash
# check-prereqs.sh: verify everything `make` needs on the host and say how to fix it.
set -u
ok=0; bad=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; ok=$((ok+1)); }
fail() { printf '  \033[31mmissing\033[0m %s\n' "$1"; printf '          %s\n' "$2"; bad=$((bad+1)); }
warn() { printf '  \033[33mnote\033[0m %s\n' "$*"; }

os=$(uname -s); arch=$(uname -m)
echo "host: $os $arch"

if command -v docker >/dev/null; then
  if docker info >/dev/null 2>&1; then
    pass "docker ($(docker version -f '{{.Server.Version}}' 2>/dev/null), server $(docker version -f '{{.Server.Os}}/{{.Server.Arch}}' 2>/dev/null))"
  else
    fail "docker daemon not reachable" "macOS: brew install colima docker && colima start --cpu 8 --memory 12 --vm-type vz --vz-rosetta;  Linux: start the docker service"
  fi
  if docker buildx version >/dev/null 2>&1; then pass "docker buildx ($(docker buildx version | awk '{print $2}'))"
  else fail "docker buildx plugin" "macOS: brew install docker-buildx && mkdir -p ~/.docker/cli-plugins && ln -sf \$(brew --prefix)/opt/docker-buildx/bin/docker-buildx ~/.docker/cli-plugins/;  Debian/Ubuntu: apt install docker-buildx-plugin"; fi
else
  fail "docker" "macOS: brew install colima docker docker-buildx;  Linux: install docker-ce + docker-buildx-plugin"
fi

if command -v qemu-system-x86_64 >/dev/null; then pass "qemu-system-x86_64 ($(qemu-system-x86_64 --version | head -1 | awk '{print $4}'))"
else fail "qemu-system-x86_64" "macOS: brew install qemu;  Debian/Ubuntu: apt install qemu-system-x86"; fi

if command -v timeout >/dev/null || command -v gtimeout >/dev/null; then pass "timeout (coreutils)"
else fail "timeout/gtimeout" "macOS: brew install coreutils"; fi

for t in make python3 openssl git lsof; do
  if command -v $t >/dev/null; then pass "$t"; else fail "$t" "install $t with your package manager"; fi
done

if [ "$os" = Linux ]; then
  if [ -w /dev/kvm ]; then pass "/dev/kvm writable (KVM acceleration)"; else warn "/dev/kvm not writable: QEMU will use TCG (slow). Add yourself to the kvm group."; fi
else
  warn "no KVM on $os: QEMU runs with TCG. Expect 3-5 s to the IEx prompt and ~12 min for 'make smoke'."
fi
if [ "$arch" = arm64 ] || [ "$arch" = aarch64 ]; then
  warn "arm64 host: OTP libraries build natively, only ERTS is cross-compiled for x86-64 (see docs/book Architecture > Build pipeline)."
fi

echo
if [ $bad -eq 0 ]; then echo "all prerequisites present ($ok checks)"; else echo "$bad missing"; exit 1; fi
