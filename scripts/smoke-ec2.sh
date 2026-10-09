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
# With DATA_SNAPSHOT=<snap-id> (make smoke-ec2 passes the ext2 data volume
# built by scripts/mkdata.sh) a 1 GiB data volume is attached as /dev/sdf, and
# the instance gets an IAM role (elixir_unikernel-smoke, created on first use)
# so the app can write to CloudWatch. The script then also checks: boot counter
# on /data, IMDS identity, NTP sync, CloudWatch log stream and BootCount metric,
# and that `aws ec2 reboot-instances` brings the node back with boot_count 2.
# Without DATA_SNAPSHOT those checks are skipped.
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

ROLE=elixir_unikernel-smoke
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
  "IpProtocol=tcp,FromPort=4443,ToPort=4443,IpRanges=[{CidrIp=$CLIENT_CIDR}]" \
  "IpProtocol=tcp,FromPort=8080,ToPort=8080,IpRanges=[{CidrIp=$CLIENT_CIDR}]" >/dev/null
echo "security group $SG (4000, 4443, 8080 from $CLIENT_CIDR)"

# IAM role + instance profile for CloudWatch (idempotent; kept between runs, tagged).
ensure_role() {
  if ! aws iam get-role --role-name "$ROLE" >/dev/null 2>&1; then
    aws iam create-role --role-name "$ROLE" --tags "Key=Project,Value=elixir_unikernel" \
      --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}' >/dev/null
    aws iam put-role-policy --role-name "$ROLE" --policy-name cloudwatch-logs --policy-document \
      '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents","logs:DescribeLogStreams"],"Resource":"*"}]}'
    echo "created IAM role $ROLE"
  fi
  if ! aws iam get-instance-profile --instance-profile-name "$ROLE" >/dev/null 2>&1; then
    aws iam create-instance-profile --instance-profile-name "$ROLE" --tags "Key=Project,Value=elixir_unikernel" >/dev/null
    aws iam add-role-to-instance-profile --instance-profile-name "$ROLE" --role-name "$ROLE"
    echo "created instance profile $ROLE; waiting for IAM to propagate"; sleep 15
  fi
}

EXTRA=()
if [ -n "${DATA_SNAPSHOT:-}" ]; then
  ensure_role
  EXTRA+=(--iam-instance-profile "Name=$ROLE")
  EXTRA+=(--block-device-mappings "[{\"DeviceName\":\"/dev/sdf\",\"Ebs\":{\"SnapshotId\":\"$DATA_SNAPSHOT\",\"VolumeSize\":1,\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]")
  # User data overrides the baked-in command line (key=value lines, see /init).
  # halt_after_first_boot makes the VM exit 75 s into the first boot: /init then
  # reboots the machine (the guest-driven restart path). Later boots stay up so
  # that reboot-instances / stop-instances can be timed.
  EXTRA+=(--user-data "uniapp.cloudwatch=1
uniapp.log_group=/elixir_unikernel/smoke
uniapp.data=auto
uniapp.halt_after_first_boot=75000")
  echo "data volume from $DATA_SNAPSHOT, role $ROLE, user data with uniapp.cloudwatch=1"
fi

INSTANCE=$(aws ec2 run-instances --image-id "$AMI" --instance-type "$INSTANCE_TYPE" --subnet-id "$SUBNET" \
  --security-group-ids "$SG" --associate-public-ip-address --count 1 \
  --instance-initiated-shutdown-behavior terminate "${EXTRA[@]}" \
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

# Health endpoint: what an ALB target group or ASG health check would call.
hz=$(curl -s --max-time 10 -w '\n%{http_code}' "http://$IP:8080/healthz" 2>/dev/null || true)
hz_code=$(echo "$hz" | tail -1); hz_body=$(echo "$hz" | sed '$d')
[ "$hz_code" = 200 ] && echo "$hz_body" | grep -q '"status":"ok"' && ok "GET /healthz -> 200 $(echo "$hz_body" | cut -c1-120)" || bad "GET /healthz -> '$hz_code' $hz_body"
lz=$(curl -s -o /dev/null --max-time 10 -w '%{http_code}' "http://$IP:8080/livez" 2>/dev/null || true)
[ "$lz" = 200 ] && ok "GET /livez -> 200" || bad "GET /livez -> '$lz'"

# Probes need the DNS/TLS round trip to the internet; give the console time to catch up.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  console > "$LOG"
  grep -q 'PROBE done' "$LOG" && break; sleep 10
done
grep -q 'PROBE dns ok' "$LOG" && ok "PROBE dns ok" || bad "PROBE dns: $(grep -m1 'PROBE dns' "$LOG" || echo missing)"
grep -q 'PROBE tls ok' "$LOG" && ok "PROBE tls ok" || bad "PROBE tls: $(grep -m1 'PROBE tls' "$LOG" || echo missing)"
for _ in 1 2 3 4 5 6; do grep -q '^BENCH tcp_echo' "$LOG" && break; sleep 10; console > "$LOG"; done
grep -q '^BENCH tcp_echo' "$LOG" && ok "$(grep -m1 '^BENCH tcp_echo' "$LOG") (guest-side echo through the NIC driver)" || bad "no BENCH line"

# Bulk transfer from here: 4 MB of 1 KiB lines through the TCP echo, MB/s round trip.
bulk=$(python3 - "$IP" <<'PY' 2>&1
import socket, sys, time, threading
host = sys.argv[1]; line = b"y" * 1023 + b"\n"; n = 4096
s = socket.create_connection((host, 4000), 10); s.settimeout(20)
t0 = time.time()
def send():
    for _ in range(n): s.sendall(line)
th = threading.Thread(target=send); th.start()
got = 0
while got < n * len(line):
    d = s.recv(1 << 16)
    if not d: break
    got += len(d)
th.join(); dt = time.time() - t0; s.close()
print("BULK %d bytes in %.0f ms = %.1f MB/s" % (got, dt*1000, got/dt/1e6))
PY
)
echo "$bulk" | grep -q '^BULK' && ok "$bulk (round trip from $MYIP)" || bad "bulk transfer: $bulk"
grep -qiE 'crash dump|Kernel panic|panicked at' "$LOG" && bad "crash in console" || ok "no crash"

if [ -n "${DATA_SNAPSHOT:-}" ]; then
  grep -qE '^\[init\] imds: i-' "$LOG" && ok "$(grep -m1 '^\[init\] imds: i-' "$LOG" | sed 's/^\[init\] //')" || bad "no IMDS identity line"
  grep -q 'user-data override' "$LOG" && ok "$(grep -m1 'user-data override' "$LOG" | sed 's/^\[init\] //')" || bad "user data not applied"
  grep -q 'ntp: synced' "$LOG" && ok "$(grep -m1 'ntp: synced' "$LOG" | sed 's/^\[init\] //')" || bad "no NTP sync: $(grep -m1 'ntp:' "$LOG" || echo missing)"
  grep -q 'data: .* mounted on /data' "$LOG" && ok "$(grep -m1 'mounted on /data' "$LOG" | sed 's/^\[init\] //')" || bad "data volume not mounted: $(grep -m1 'data:' "$LOG" || echo missing)"
  grep -q '^DATA boot_count 1 ' "$LOG" && ok "boot_count 1 on /data" || bad "boot counter: $(grep -m1 '^DATA' "$LOG" || echo missing)"
  grep -q '^CLOUDWATCH ' "$LOG" && ok "$(grep -m1 '^CLOUDWATCH' "$LOG")" || bad "CloudWatch shipper not started"

  # The VM exits (uniapp.eval above), /init reboots the machine, the second boot
  # must find the data volume with boot_count 1 and bump it.
  echo "waiting for the guest-initiated reboot (VM exit at +75 s)"
  T1=$(date +%s)
  rebooted=""
  while [ $(( $(date +%s) - T1 )) -lt $(( BOOT_TIMEOUT + 90 )) ]; do
    console > "$LOG.reboot"
    if grep -q '^DATA boot_count 2 ' "$LOG.reboot"; then rebooted=$(( $(date +%s) - T0 )); break; fi
    sleep 5
  done
  grep -q 'beam.smp exited with status 0' "$LOG.reboot" && ok "$(grep -m1 'beam.smp exited' "$LOG.reboot" | sed 's/^\[init\] //'), then: $(grep -m1 -E '^\[init\] (rebooting|powering off)' "$LOG.reboot" | sed 's/^\[init\] //')" || bad "no 'beam.smp exited' line: $(grep -m1 'beam.smp' "$LOG.reboot" || echo missing)"
  if [ -n "$rebooted" ]; then ok "second boot: boot_count 2 on /data (${rebooted}s after launch)"; else bad "boot_count 2 not seen after the reboot: $(grep -m1 '^DATA' "$LOG.reboot" || echo missing)"; fi

  # CloudWatch: the stream exists and carries our log line and an EMF document.
  group=/elixir_unikernel/smoke
  for _ in 1 2 3 4 5 6; do
    events=$(aws logs filter-log-events --log-group-name "$group" --log-stream-names "$INSTANCE" --filter-pattern '"echo: listening"' --query 'length(events)' --output text 2>/dev/null || echo 0)
    [ "$events" != "0" ] && [ "$events" != "None" ] && break; sleep 10
  done
  [ "$events" != "0" ] && [ "$events" != "None" ] && ok "CloudWatch Logs: $events 'echo: listening' events in $group/$INSTANCE" || bad "CloudWatch Logs: no 'echo: listening' event in $group/$INSTANCE"
  emf=$(aws logs filter-log-events --log-group-name "$group" --log-stream-names "$INSTANCE" --filter-pattern '"BootCount"' --query 'length(events)' --output text 2>/dev/null || echo 0)
  [ "$emf" != "0" ] && [ "$emf" != "None" ] && ok "CloudWatch EMF: BootCount metric documents ($emf)" || bad "no EMF BootCount document"

  # EC2 API reboot: an ACPI power-button press. The kernel turns it into SIGPWR,
  # /init stops the VM and powers off, EC2 restarts the instance. Without that
  # EC2 waits about 4 minutes before hard-resetting, so time is the proof.
  echo "aws ec2 reboot-instances $INSTANCE"
  T2=$(date +%s)
  aws ec2 reboot-instances --instance-ids "$INSTANCE"
  api_rebooted=""
  while [ $(( $(date +%s) - T2 )) -lt 180 ]; do
    console > "$LOG.api-reboot"
    if grep -q '^DATA boot_count 3 ' "$LOG.api-reboot"; then api_rebooted=$(( $(date +%s) - T2 )); break; fi
    sleep 5
  done
  # Asterinas: the kernel logs the press and sends SIGPWR; Linux: /init reads KEY_POWER from evdev.
  grep -qE 'acpi: power button pressed|\[init\] power button \(evdev\)' "$LOG.api-reboot" && ok "power button seen: $(grep -m1 -E 'acpi: power button pressed|power button \(evdev\)' "$LOG.api-reboot" | sed 's/^\[kernel\] //; s/^\[init\] //')" || bad "no power button event in the console"
  grep -q 'SIGTERM received' "$LOG.api-reboot" && ok "ERTS shut down on SIGTERM" || bad "no 'SIGTERM received' from ERTS"
  grep -q '^\[init\] powering off' "$LOG.api-reboot" && ok "/init powered off" || bad "no '/init powering off'"
  if [ -n "$api_rebooted" ]; then ok "reboot-instances: boot_count 3 on the console ${api_rebooted}s after the call (hard reset would take 240+ s)"; else bad "boot_count 3 not seen within 180 s of reboot-instances: $(grep -m1 '^DATA' "$LOG.api-reboot" || echo missing)"; fi

  # EC2 API stop: the same button press; the guest must reach S5 for the
  # instance to leave 'stopping' quickly.
  echo "aws ec2 stop-instances $INSTANCE"
  T3=$(date +%s)
  aws ec2 stop-instances --instance-ids "$INSTANCE" >/dev/null
  stopped=""
  while [ $(( $(date +%s) - T3 )) -lt 240 ]; do
    st=$(aws ec2 describe-instances --instance-ids "$INSTANCE" --query 'Reservations[0].Instances[0].State.Name' --output text)
    if [ "$st" = stopped ]; then stopped=$(( $(date +%s) - T3 )); break; fi
    sleep 5
  done
  if [ -n "$stopped" ] && [ "$stopped" -lt 150 ]; then ok "stop-instances: state 'stopped' after ${stopped}s (hard stop would take 240+ s)"; else bad "stop-instances: state '${st}' after $(( $(date +%s) - T3 ))s"; fi
fi

echo "SMOKE $LABEL ($AMI on $INSTANCE_TYPE): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
