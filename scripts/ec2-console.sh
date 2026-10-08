#!/usr/bin/env bash
# Read an instance's console, two ways.
#
#   scripts/ec2-console.sh <instance-id>            # GetConsoleOutput snapshot (read-only, lags ~30 s)
#   scripts/ec2-console.sh <instance-id> --attach   # interactive EC2 Serial Console over SSH (IEx lives here)
#
# --attach needs serial console access enabled once per account
# (`aws ec2 enable-serial-console-access`) and the IAM permission
# ec2-instance-connect:SendSerialConsoleSSHPublicKey. It pushes a one-off
# SSH key and connects to the regional serial console endpoint; type `~.`
# to leave the session. The image has no login prompt: the serial line is
# the Erlang VM's stdio, so you land in IEx (uniapp.mode=iex) or see the
# application log (uniapp.mode=app).
set -euo pipefail
INSTANCE=$1; MODE=${2:-}
REGION=${AWS_REGION:-${AWS_DEFAULT_REGION:-$(aws configure get region)}}

if [ "$MODE" != "--attach" ]; then
  aws ec2 get-console-output --instance-id "$INSTANCE" --latest --query Output --output text \
    | sed 's/\x1b\[[0-9;?=]*[A-Za-z]//g; s/\r//g' | grep -v '^None$'
  exit 0
fi

KEY=$(mktemp -d)/serial
ssh-keygen -q -t ed25519 -N '' -f "$KEY"
aws ec2-instance-connect send-serial-console-ssh-public-key --instance-id "$INSTANCE" \
  --serial-port 0 --ssh-public-key "file://$KEY.pub" >/dev/null
echo "connecting to $INSTANCE serial port 0 (exit with ~.)" >&2
exec ssh -i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  "$INSTANCE.port0@serial-console.ec2-instance-connect.$REGION.aws"
