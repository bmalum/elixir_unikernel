#!/usr/bin/env bash
# Turns builder/asterinas-patches into commits on upstream Asterinas 3d85cb44,
# one topic branch per upstreamable unit plus `elixir-unikernel-all`, in a
# clone of the fork at $FORK (default build/aster-fork, github.com/bmalum/asterinas).
# Commit messages come from the manual's patch chapter (build/patch-msgs, see
# below). Pass --push to push every branch to origin.
#
#   scripts/upstream-branches.sh [--push]
set -euo pipefail
PUSH=${1:-}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
FORK=${FORK:-$PWD/build/aster-fork}
BASE=3d85cb44263808723ee46c5dbbd06b330a2b3204
P=$ROOT/builder/asterinas-patches
M=$ROOT/build/patch-msgs

# Commit bodies: the per-patch sections of the manual.
mkdir -p "$M"
python3 - "$ROOT/docs/book/src/internals/asterinas-patches.md" "$M" <<'PY'
import re, sys, json
s=open(sys.argv[1]).read(); out=sys.argv[2]
secs=re.split(r'^## (\d{4}): ', s, flags=re.M); titles={}
for i in range(1,len(secs),2):
    num=secs[i]; title,_,rest=secs[i+1].partition('\n')
    rest=re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', rest.split('\n## ')[0].strip())
    open(f'{out}/{num}.txt','w').write(rest+'\n'); titles[num]=title.strip().replace('`','')
json.dump(titles, open(f'{out}/titles.json','w'))
PY

[ -d "$FORK/.git" ] || git clone -q --filter=blob:none https://github.com/bmalum/asterinas.git "$FORK"
cd "$FORK"
git cat-file -e "$BASE^{commit}" 2>/dev/null || git fetch -q "$ROOT/build/asterinas-src" "$BASE"

commit_patch() { n=$1; f=$(ls "$P"/$n-*.patch); title=$(python3 -c "import json;print(json.load(open('$M/titles.json'))['$n'])")
  git apply "$f"; git add -A
  git -c user.name=bmalum -c user.email=support@bmalum.com commit -q -F - <<MSG
$2: $title

$(cat "$M/$n.txt")

Found while running Erlang/Elixir (elixir_unikernel) on Asterinas, where this
is applied as builder/asterinas-patches/$(basename "$f").
Base: 3d85cb44. Project: https://github.com/bmalum/elixir_unikernel
MSG
}
area() { case $1 in 0001|0003|0004) echo net;; 0002) echo time;; 0005|0009) echo ena;; 0006) echo x86;; 0007) echo nvme;; 0008) echo acpi;; esac; }
mk() { git checkout -q -B "$1" "$BASE"; }
mk fix/bind-unspecified-address;    commit_patch 0001 net
mk fix/timerfd-settime-readiness;   commit_patch 0002 time
mk feat/x86-poweroff-clock-settime; commit_patch 0006 x86
mk fix/nvme-mqes-number-of-queues;  commit_patch 0007 nvme
mk feat/acpi-power-button-s5;       commit_patch 0006 x86; commit_patch 0008 acpi   # 0008 builds on 0006's power.rs
mk feat/net-runtime-ifconfig-dhcp;  commit_patch 0003 net; commit_patch 0004 net
mk feat/ena-driver; commit_patch 0003 net; commit_patch 0004 net; commit_patch 0005 ena; commit_patch 0009 ena
mk elixir-unikernel-all; for n in 0001 0002 0003 0004 0005 0006 0007 0008 0009; do commit_patch $n "$(area $n)"; done
BRANCHES=$(git branch --list 'fix/*' 'feat/*' 'elixir-unikernel-all' | tr -d ' *')
echo "$BRANCHES"
if [ "$PUSH" = --push ]; then
  for b in $BRANCHES; do git push -q -f -u origin "$b" && echo "pushed $b"; done
fi
