#!/usr/bin/env bash
# Boot an AMI on EC2 and run the elixir_unikernel assertions against it.
#
#   scripts/smoke-ec2.sh <ami-id> [label]
#
# Launches one t3.small (INSTANCE_TYPE) in the default VPC with a throwaway
# security group that allows 4000/tcp and 4443/tcp from this machine's public
# address only, then:
#   - polls GetConsoleOutput for "uniapp starting" (BOOT_TIMEOUT, default 120 s)
#   - echoes through TCP 4000 and TLS 1.3 4443 from here
#   - checks "PROBE dns ok" / "PROBE tls ok" in the console
# The instance is terminated and the security group deleted on every exit
# path (EXIT trap), including Ctrl-C. Full console output is saved to
# build/logs/ec2-<label>.log. Everything is tagged Project=elixir_unikernel.
#
# KEEP=1 skips termination (prints the instance id and the console command).
# CLIENT_CIDR overrides the source range; the default is the /24 around this
# machine's public address, because NAT pools (e.g. corporate egress) rotate
# the source address between connections.
# Needs: aws cli with AWS_PROFILE/AWS_REGION, python3, openssl, curl.
set -euo pipefail
AMI=$1; LABEL=${2:-ec2}
INSTANCE_TYPE=${INSTANCE_TYPE:-t3.small}
BOOT_TIMEOUT=${BOOT_TIMEOUT:-120}
VERSION=$(cat "$(dirname "$0")/../VERSION")
LOGDIR=$(dirname "$0")/../build/logs; mkdir -p "$LOGDIR"
LOG=$LOGDIR/ec2-$LABEL.log
TAGS="{Key=Project,Value=elixir_unikernel},{Key=Version,Value=$VERSION},{Key=Name,Value=elixir_unikernel-smoke-$LABEL}"
PASS=0; FAIL=0
ok()  { echo "  PASS $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }

INSTANCE=""; SG=""
cleanup() {
  set +e
  if [ -n "$INSTANCE" ]; then
    if [ "${KEEP:-0}" = 1 ]; then
      echo "KEEP=1: leaving $INSTANCE running. Console: scripts/ec2-console.sh $INSTANCE; terminate: aws ec2 terminate-instances --instance-ids $INSTANCE"
      return
    fi
    aws ec2 terminate-instances --instance-ids "$INSTANCE" --output text --query 'TerminatingInstances[0].InstanceId' | sed 's/^/terminated /'
    aws ec2 wait instance-terminated --instance-ids "$INSTANCE"
  fi
  if [ -n "$SG" ]; then
    for _ in 1 2 3 4 5 6; do aws ec2 delete-security-group --group-id "$SG" >/dev/null 2>&1 && { echo "deleted $SG"; break; }; sleep 5; done
  fi
}
trap cleanup EXIT

MYIP=$(curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')
CLIENT_CIDR=${CLIENT_CIDR:-${MYIP%.*}.0/24}
VPC=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNET=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text)
SG=$(aws ec2 create-security-group --group-name "elixir_unikernel-smoke-$LABEL-$$" --description "elixir_unikernel smoke test (temporary)" \
      --vpc-id "$VPC" --tag-specifications "ResourceType=security-group,Tags=[$TAGS]" --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG" --ip-permissions \
  "IpProtocol=tcp,FromPort=4000,ToPort=4000,IpRanges=[{CidrIp=$CLIENT_CIDR}]" \
  "IpProtocol=tcp,FromPort=4443,ToPort=4443,IpRanges=[{CidrIp=$CLIENT_CIDR}]" >/dev/null
echo "security group $SG (4000, 4443 from $CLIENT_CIDR)"

INSTANCE=$(aws ec2 run-instances --image-id "$AMI" --instance-type "$INSTANCE_TYPE" --subnet-id "$SUBNET" \
  --security-group-ids "$SG" --associate-public-ip-address --count 1 \
  --instance-initiated-shutdown-behavior terminate \
  --tag-specifications "ResourceType=instance,Tags=[$TAGS]" "ResourceType=volume,Tags=[$TAGS]" \
  --query 'Instances[0].InstanceId' --output text)
echo "instance $INSTANCE ($INSTANCE_TYPE, $AMI); console log -> $LOG"
T0=$(date +%s)
aws ec2 wait instance-running --instance-ids "$INSTANCE"
IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "public ip $IP, running after $(( $(date +%s) - T0 )) s"

# GetConsoleOutput is best effort and lags by tens of seconds; poll it.
console() { aws ec2 get-console-output --instance-id "$INSTANCE" --latest --query Output --output text 2>/dev/null | sed 's/\x1b\[[0-9;?=]*[A-Za-z]//g; s/\r//g' | grep -v '^None$' || true; }
booted=""
while [ $(( $(date +%s) - T0 )) -lt "$BOOT_TIMEOUT" ]; do
  console > "$LOG"
  if grep -q 'uniapp starting' "$LOG"; then booted=$(( $(date +%s) - T0 )); break; fi
  sleep 5
done
if [ -n "$booted" ]; then ok "uniapp starting on the console after ${booted}s (limit ${BOOT_TIMEOUT}s)"; else bad "no 'uniapp starting' within ${BOOT_TIMEOUT}s"; fi
grep -q '^\[init\] net: ' "$LOG" && ok "init configured the NIC: $(grep -m1 '^\[init\] net: ' "$LOG" | sed 's/^\[init\] //')" || bad "no '[init] net:' line"
grep -qi 'dhcp' "$LOG" && ok "address came from DHCP" || bad "no DHCP in console"

# Servers may come up a few seconds after "uniapp starting"; retry the clients briefly.
tcp_ok=""; for _ in 1 2 3 4 5 6; do
  r=$(python3 - "$IP" <<'PY' 2>&1
import socket, sys
try:
    s = socket.create_connection((sys.argv[1], 4000), 5); s.sendall(b"hello\n"); print("TCP", s.recv(100) == b"hello\n"); s.close()
except Exception as e: print("TCP False", e)
PY
)
  [ "$r" = "TCP True" ] && { tcp_ok=1; break; }; sleep 5
done
[ -n "$tcp_ok" ] && ok "internet -> instance TCP 4000 echo" || bad "TCP echo: $r"
tls=$( (echo "tls-hello"; sleep 2) | timeout 20 openssl s_client -connect "$IP:4443" -tls1_3 -quiet 2>/dev/null | head -1 || true)
[ "$tls" = "tls-hello" ] && ok "internet -> instance TLS 1.3 4443 echo" || bad "TLS echo: '$tls'"

# Probes need the DNS/TLS round trip to the internet; give the console time to catch up.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  console > "$LOG"
  grep -q 'PROBE done' "$LOG" && break; sleep 10
done
grep -q 'PROBE dns ok' "$LOG" && ok "PROBE dns ok" || bad "PROBE dns: $(grep -m1 'PROBE dns' "$LOG" || echo missing)"
grep -q 'PROBE tls ok' "$LOG" && ok "PROBE tls ok" || bad "PROBE tls: $(grep -m1 'PROBE tls' "$LOG" || echo missing)"
grep -qiE 'crash dump|Kernel panic|panicked at' "$LOG" && bad "crash in console" || ok "no crash"

echo "SMOKE $LABEL ($AMI on $INSTANCE_TYPE): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
