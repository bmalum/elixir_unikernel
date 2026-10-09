#!/usr/bin/env bash
# NIC-to-NIC throughput: two instances of the same AMI in one subnet; the
# second pushes 32 MB through the first's TCP echo and prints the round-trip
# rate on its console (BENCH tcp_echo_peer). Both ENA, same AZ, so this is the
# driver's number, not the internet's. Terminates both on every exit.
#
#   scripts/bench-ec2.sh <ami-id> [extra user-data lines...]
#
# INSTANCE_TYPE (t3.small) applies to both. Prints the BENCH line.
set -euo pipefail
AMI=$1; shift
EXTRA_UD=${*:-}
INSTANCE_TYPE=${INSTANCE_TYPE:-t3.small}
VERSION=$(cat "$(dirname "$0")/../VERSION")
TAGS="{Key=Project,Value=elixir_unikernel},{Key=Version,Value=$VERSION},{Key=Name,Value=elixir_unikernel-bench}"
LOGDIR=$(dirname "$0")/../build/logs; mkdir -p "$LOGDIR"
export PATH="/opt/homebrew/opt/coreutils/libexec/gnubin:$PATH"

A=""; B=""; SG=""
cleanup() {
  set +e
  ids="$A $B"; ids=$(echo $ids)
  [ -n "$ids" ] && aws ec2 terminate-instances --instance-ids $ids --query 'TerminatingInstances[].InstanceId' --output text | sed 's/^/terminated /' && aws ec2 wait instance-terminated --instance-ids $ids
  [ -n "$SG" ] && for _ in 1 2 3 4 5 6; do aws ec2 delete-security-group --group-id "$SG" >/dev/null 2>&1 && { echo "deleted $SG"; break; }; sleep 5; done
}
trap cleanup EXIT

VPC=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNET=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text)
SG=$(aws ec2 create-security-group --group-name "elixir_unikernel-bench-$$" --description "elixir_unikernel bench (temporary)" \
      --vpc-id "$VPC" --tag-specifications "ResourceType=security-group,Tags=[$TAGS]" --query GroupId --output text)
# Instances talk to each other on 4000 only.
aws ec2 authorize-security-group-ingress --group-id "$SG" --ip-permissions \
  "IpProtocol=tcp,FromPort=4000,ToPort=4000,UserIdGroupPairs=[{GroupId=$SG}]" >/dev/null

run() { # $1 name, $2 user data
  aws ec2 run-instances --image-id "$AMI" --instance-type "$INSTANCE_TYPE" --subnet-id "$SUBNET" \
    --security-group-ids "$SG" --count 1 --instance-initiated-shutdown-behavior terminate \
    --user-data "$2" --tag-specifications "ResourceType=instance,Tags=[$TAGS]" \
    --query 'Instances[0].InstanceId' --output text
}
A=$(run a "uniapp.on_exit=poweroff
$EXTRA_UD")
aws ec2 wait instance-running --instance-ids "$A"
A_IP=$(aws ec2 describe-instances --instance-ids "$A" --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
echo "echo server $A at $A_IP"
B=$(run b "uniapp.on_exit=poweroff
uniapp.bench_peer=$A_IP
uniapp.bench_delay_ms=20000
$EXTRA_UD")
echo "sender $B; waiting for BENCH tcp_echo_peer on its console"
aws ec2 wait instance-running --instance-ids "$B"
T0=$(date +%s); line=""
while [ $(( $(date +%s) - T0 )) -lt 240 ]; do
  out=$(aws ec2 get-console-output --instance-id "$B" --latest --query Output --output text 2>/dev/null | sed 's/\x1b\[[0-9;?=]*[A-Za-z]//g; s/\r//g')
  echo "$out" > "$LOGDIR/bench-sender.log"
  line=$(echo "$out" | grep -m1 '^BENCH tcp_echo_peer' || true)
  [ -n "$line" ] && break
  sleep 10
done
aws ec2 get-console-output --instance-id "$A" --latest --query Output --output text 2>/dev/null | sed 's/\x1b\[[0-9;?=]*[A-Za-z]//g; s/\r//g' > "$LOGDIR/bench-echo.log" || true
if [ -n "$line" ]; then
  echo "$line ($INSTANCE_TYPE -> $INSTANCE_TYPE, same subnet; $(grep -m1 -oE 'ena: .* ready, .*' "$LOGDIR/bench-sender.log" | cut -c1-90))"
else
  echo "no BENCH tcp_echo_peer within 240 s; sender console:"; grep -E 'BENCH|ena|error|PROBE' "$LOGDIR/bench-sender.log" | tail -8; exit 1
fi
