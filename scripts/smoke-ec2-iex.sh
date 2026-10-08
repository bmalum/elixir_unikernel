#!/usr/bin/env bash
# Prove IEx over the EC2 Serial Console: launch an AMI built with
# DISK_MODE=iex, attach to serial port 0 via EC2 Instance Connect, type
# `1 + 2` at the `iex(1)>` prompt and expect `3`. Terminates the instance on
# every exit path. Transcript in build/logs/ec2-iex.log.
#
#   scripts/smoke-ec2-iex.sh <ami-id>
#
# Needs serial console access enabled once per account:
#   aws ec2 enable-serial-console-access
set -euo pipefail
AMI=$1
INSTANCE_TYPE=${INSTANCE_TYPE:-t3.small}
VERSION=$(cat "$(dirname "$0")/../VERSION")
REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region)}}
LOGDIR=$(dirname "$0")/../build/logs; mkdir -p "$LOGDIR"; LOG=$LOGDIR/ec2-iex.log
TAGS="{Key=Project,Value=elixir_unikernel},{Key=Version,Value=$VERSION},{Key=Name,Value=elixir_unikernel-smoke-iex}"
export PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:$PATH"

INSTANCE=""; KEYDIR=$(mktemp -d)
cleanup() {
  set +e
  if [ -n "$INSTANCE" ]; then
    aws ec2 terminate-instances --instance-ids "$INSTANCE" --output text --query 'TerminatingInstances[0].InstanceId' | sed 's/^/terminated /'
  fi
  rm -rf "$KEYDIR"
}
trap cleanup EXIT

[ "$(aws ec2 get-serial-console-access-status --query SerialConsoleAccessEnabled --output text)" = True ] \
  || { echo "serial console access is disabled; run: aws ec2 enable-serial-console-access" >&2; exit 2; }

INSTANCE=$(aws ec2 run-instances --image-id "$AMI" --instance-type "$INSTANCE_TYPE" --count 1 \
  --instance-initiated-shutdown-behavior terminate \
  --tag-specifications "ResourceType=instance,Tags=[$TAGS]" "ResourceType=volume,Tags=[$TAGS]" \
  --query 'Instances[0].InstanceId' --output text)
echo "instance $INSTANCE ($AMI); transcript -> $LOG"
aws ec2 wait instance-running --instance-ids "$INSTANCE"

ssh-keygen -q -t ed25519 -N '' -f "$KEYDIR/k"
# Wait for the guest to reach the prompt before attaching (boot takes ~40 s; the
# serial console has no scrollback, so what we type is all we see).
sleep 50
: > "$LOG"
for attempt in 1 2 3; do
  # Keys are valid for 60 s and the endpoint accepts them only once the instance is up.
  aws ec2-instance-connect send-serial-console-ssh-public-key --instance-id "$INSTANCE" \
    --serial-port 0 --ssh-public-key "file://$KEYDIR/k.pub" >/dev/null 2>"$LOGDIR/ec2-iex-key.err" \
    || { echo "  (key push failed: $(tr -d '\n' < "$LOGDIR/ec2-iex-key.err"), retrying)"; sleep 10; continue; }
  # Attach, type the expression, read the answer, detach with ~.
  timeout 60 bash -c '
    { sleep 8; printf "1 + 2\r"; sleep 6; printf "~."; } \
    | ssh -tt -i "$1" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "$2.port0@serial-console.ec2-instance-connect.$3.aws"' _ "$KEYDIR/k" "$INSTANCE" "$REGION" 2>"$LOGDIR/ec2-iex-ssh.err" \
    | sed 's/\x1b\[[0-9;?=]*[A-Za-z]//g; s/\r//g' > "$LOG" || true
  grep -qE '^3$' "$LOG" && break
  echo "  (attempt $attempt: $(wc -c < "$LOG") bytes from the console; ssh: $(tr -d '\n' < "$LOGDIR/ec2-iex-ssh.err" | cut -c1-120))"
  sleep 10
done

# The live session has no scrollback; the boot transcript comes from GetConsoleOutput.
BOOTLOG=$LOGDIR/ec2-iex-boot.log
aws ec2 get-console-output --instance-id "$INSTANCE" --latest --query Output --output text 2>/dev/null \
  | sed 's/\x1b\[[0-9;?=]*[A-Za-z]//g; s/\r//g' | grep -v '^None$' > "$BOOTLOG" || true

PASS=0; FAIL=0
grep -q 'Interactive Elixir' "$BOOTLOG" && { echo "  PASS IEx banner on the serial console"; PASS=$((PASS+1)); } || { echo "  FAIL no IEx banner in $BOOTLOG"; FAIL=$((FAIL+1)); }
grep -q '^\[init\] net: ' "$BOOTLOG" && { echo "  PASS $(grep -m1 '^\[init\] net: ' "$BOOTLOG")"; PASS=$((PASS+1)); } || { echo "  FAIL no '[init] net:' line"; FAIL=$((FAIL+1)); }
# The prompt we typed at was printed before we attached (no scrollback), so the
# session shows the echoed expression, the result and the next prompt.
grep -qE '^1 \+ 2$' "$LOG" && { echo "  PASS '1 + 2' echoed by IEx over the serial console"; PASS=$((PASS+1)); } || { echo "  FAIL expression not echoed"; FAIL=$((FAIL+1)); }
grep -A1 -E '^1 \+ 2$' "$LOG" | grep -qE '^3$' && { echo "  PASS result 3"; PASS=$((PASS+1)); } || { echo "  FAIL no result"; FAIL=$((FAIL+1)); }
grep -qE '^iex\([0-9]+\)> ' "$LOG" && { echo "  PASS next iex prompt"; PASS=$((PASS+1)); } || { echo "  FAIL no prompt after the result"; FAIL=$((FAIL+1)); }
echo "SMOKE iex ($AMI): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
