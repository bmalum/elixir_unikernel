#!/usr/bin/env bash
# smoke.sh <label> "<qemu command without -append>" "<base cmdline>"
#
# Boots the image twice (app mode, then iex mode) with a timeout, captures the
# serial console, and asserts GOALS.md criteria 1-3:
#   app mode : PROBE udp/tcp/tls_srv ok, PROBE dns/tls ok (if tls_host given),
#              gen_tcp listen message, no crash
#   iex mode : IEx banner + prompt; typed expressions are evaluated
# Prints boot timing. Exit code != 0 on any failure.
set -uo pipefail
trap '' PIPE   # writing Ctrl-a x into the FIFO of an already-dead QEMU must not kill us
LABEL=$1; QEMU_CMD=$2; CMDLINE=$3; MKDISK=${4:-}
# Two ways to pass the kernel command line: -append (direct kernel boot), or,
# when a 4th argument "mkdisk command" is given, rebuild the disk image with the
# command line baked into GRUB before each run (UEFI disk boot).
start_qemu() { # <mode> <fifo> <log>
  if [ -n "$MKDISK" ]; then
    $MKDISK "$CMDLINE uniapp.mode=$1" >/dev/null 2>&1 || { echo "mkdisk failed" >&2; return 1; }
    $TIMEOUT_BIN "$TIMEOUT" $QEMU_CMD < "$2" > "$3" 2>&1 &
  else
    $TIMEOUT_BIN "$TIMEOUT" $QEMU_CMD -append "$CMDLINE uniapp.mode=$1" < "$2" > "$3" 2>&1 &
  fi
}
TIMEOUT=${SMOKE_TIMEOUT:-240}
# Asterinas under QEMU TCG occasionally stalls right after exec'ing beam.smp
# (upstream kernel too, see RESEARCH.md). A boot that has not printed
# "uniapp starting" within BOOT_TIMEOUT is killed and retried, up to ATTEMPTS.
BOOT_TIMEOUT=${SMOKE_BOOT_TIMEOUT:-60}
ATTEMPTS=${SMOKE_ATTEMPTS:-5}
LOGDIR=${SMOKE_LOGDIR:-build/logs}; mkdir -p "$LOGDIR"
TIMEOUT_BIN=timeout; command -v timeout >/dev/null || TIMEOUT_BIN=gtimeout
fail=0

ok()  { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=1; }
# FIFO plumbing for QEMU's stdin: a background "holder" keeps the write end
# open so QEMU never sees EOF; input is sent with a bounded timeout so a dead
# QEMU (no reader) cannot block or SIGPIPE us.
# The holder opens the FIFO read-write: opening write-only would block until a
# reader (QEMU, started later) appears and deadlock the $(...) capture.
fifo_open()  { mkfifo "$1"; sleep 100000 3<> "$1" >/dev/null 2>&1 & echo $!; }
fifo_send()  { $TIMEOUT_BIN 3 sh -c 'printf "%s" "$1" > "$2"' _ "$2" "$1" 2>/dev/null || true; }
strip_ansi() { sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\x1bc//g' -e 's/\r$//' "$1" > "$1.clean"; }

# run_vm <mode> <wait-for-regex> <input-to-type> <stop-regex>
# Starts QEMU with stdin from a FIFO; types <input> once <wait-for-regex> is
# seen on the console; stops when <stop-regex> appears or on timeout.
run_vm() {
  local mode waitre input stopre log fifo qpid typed t attempt booted done_ holder
  mode=$1; waitre=$2; input=$3; stopre=$4; log="$LOGDIR/$LABEL-$mode.log"
  for attempt in $(seq 1 "$ATTEMPTS"); do
    fifo=$(mktemp -u); holder=$(fifo_open "$fifo")
    : > "$log"
    start_qemu "$mode" "$fifo" "$log"; qpid=$!
    typed=0; t=0; booted=0; done_=0
    while kill -0 $qpid 2>/dev/null && [ $t -lt "$TIMEOUT" ]; do
      sleep 1; t=$((t+1))
      [ $booted -eq 0 ] && grep -q 'uniapp starting' "$log" && booted=1
      if [ $booted -eq 0 ] && [ $t -ge "$BOOT_TIMEOUT" ]; then break; fi   # stalled boot
      if [ $typed -eq 0 ] && grep -qE "$waitre" "$log"; then
        sleep 2; fifo_send "$fifo" "$input"; typed=1
      fi
      if grep -qE "$stopre" "$log"; then sleep 2; done_=1; break; fi
      # typed, but no reaction within BOOT_TIMEOUT: stalled mid-run
      if [ $typed -eq 1 ] && [ $t -ge $((BOOT_TIMEOUT * 2)) ]; then break; fi
    done
    fifo_send "$fifo" $'\001x'       # Ctrl-a x: quit QEMU
    sleep 1; kill $qpid $holder 2>/dev/null; wait $qpid 2>/dev/null
    rm -f "$fifo"
    [ $done_ -eq 1 ] && break
    echo "  info: $mode run stalled (booted=$booted) after ${t}s (attempt $attempt/$ATTEMPTS), retrying" >&2
    cp "$log" "$log.stalled.$attempt"
  done
  strip_ansi "$log"
  echo "$log.clean"
}

# Host-side clients against the guest's echo servers (QEMU hostfwd 4000/4001/4443).
HOST_PORT_TCP=${HOST_PORT_TCP:-4000}; HOST_PORT_UDP=${HOST_PORT_UDP:-4001}; HOST_PORT_TLS=${HOST_PORT_TLS:-4443}
client_checks() {
  python3 - "$HOST_PORT_TCP" "$HOST_PORT_UDP" <<'PY' 2>&1
import socket, sys
tcp, udp = int(sys.argv[1]), int(sys.argv[2])
try:
    s = socket.create_connection(("127.0.0.1", tcp), 5); s.sendall(b"hello\n"); print("TCP", s.recv(100) == b"hello\n"); s.close()
except Exception as e: print("TCP False", e)
try:
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.settimeout(5); u.sendto(b"ping", ("127.0.0.1", udp)); print("UDP", u.recvfrom(100)[0] == b"ping")
except Exception as e: print("UDP False", e)
PY
  out=$( (echo "tls-hello"; sleep 2) | $TIMEOUT_BIN 15 openssl s_client -connect 127.0.0.1:$HOST_PORT_TLS -tls1_3 -quiet 2>/dev/null | head -1)
  [ "$out" = "tls-hello" ] && echo "TLS True" || echo "TLS False ($out)"
}

# Fail fast if a previous QEMU still holds our forwarded host ports.
for port in "$HOST_PORT_TCP" "$HOST_PORT_TLS"; do
  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "host port $port is in use ($(lsof -nP -iTCP:"$port" -sTCP:LISTEN | tail -1 | awk '{print $1, $2}')); set HOST_PORT_* or stop that process" >&2
    exit 2
  fi
done

echo "== $LABEL: app mode"
# run_vm types <input> after <waitre>; we abuse the hook to run host clients instead.
run_vm_app() {
  local log="$LOGDIR/$LABEL-app.log" qpid t attempt booted fifo holder done_
  : > "$LOGDIR/$LABEL-clients.log"
  for attempt in $(seq 1 "$ATTEMPTS"); do
    fifo=$(mktemp -u); holder=$(fifo_open "$fifo")
    : > "$log"
    start_qemu app "$fifo" "$log"; qpid=$!
    t=0; booted=0; done_=0
    while kill -0 $qpid 2>/dev/null && [ $t -lt "$TIMEOUT" ]; do
      sleep 1; t=$((t+1))
      [ $booted -eq 0 ] && grep -q 'uniapp starting' "$log" && booted=1
      if [ $booted -eq 0 ] && [ $t -ge "$BOOT_TIMEOUT" ]; then break; fi
      if [ "$(grep -cE '^LISTEN (tcp|udp|tls) ' "$log")" -ge 3 ] && grep -q 'PROBE done' "$log"; then
        sleep 2; client_checks > "$LOGDIR/$LABEL-clients.log"; done_=1; break
      fi
      # booted but probes never finished within 2x BOOT_TIMEOUT: stalled mid-run
      if [ $booted -eq 1 ] && [ $t -ge $((BOOT_TIMEOUT * 3)) ]; then break; fi
    done
    fifo_send "$fifo" $'\001x'
    sleep 1; kill $qpid $holder 2>/dev/null; wait $qpid 2>/dev/null
    rm -f "$fifo"
    [ $done_ -eq 1 ] && break
    echo "  info: app run stalled (booted=$booted) after ${t}s (attempt $attempt/$ATTEMPTS), retrying" >&2
    cp "$log" "$log.stalled.$attempt"
  done
  strip_ansi "$log"; echo "$log.clean"
}
log=$(run_vm_app)
grep -q '\[init\] exec'        "$log" && ok "init exec'd beam.smp"   || bad "init did not exec beam.smp"
grep -q 'uniapp starting'      "$log" && ok "application started"    || bad "application did not start"
for k in tcp udp tls; do
  grep -qE "^LISTEN $k " "$log" && ok "$k server listening" || bad "$k server not listening"
done
C="$LOGDIR/$LABEL-clients.log"
grep -q '^TCP True' "$C" 2>/dev/null && ok "host -> guest gen_tcp echo"  || bad "gen_tcp echo from host: $(grep TCP "$C" 2>/dev/null)"
grep -q '^UDP True' "$C" 2>/dev/null && ok "host -> guest gen_udp echo"  || bad "gen_udp echo from host: $(grep UDP "$C" 2>/dev/null)"
grep -q '^TLS True' "$C" 2>/dev/null && ok "host -> guest ssl echo (TLS 1.3)" || bad "ssl echo from host: $(grep TLS "$C" 2>/dev/null)"
if [[ "$CMDLINE" == *uniapp.tls_host=* ]]; then
  for p in dns tls; do
    grep -q "PROBE $p ok" "$log" && ok "probe $p" || bad "probe $p: $(grep "PROBE $p" "$log" | head -1)"
  done
fi
grep -qiE 'Crash dump|Kernel panic|Uncaught panic|Environment variable BINDIR|erl_child_setup: ' "$log" && bad "crash/panic in log" || ok "no crash"
grep -qE 'iex\(' "$log" && bad "app mode must not start IEx" || ok "no shell in app mode"

echo "== $LABEL: iex mode"
log=$(run_vm iex 'iex\([^)]*\)[0-9]*>' $'IO.puts(1 + 2)\nIO.puts("otp=" <> System.otp_release())\n' 'otp=[0-9]+')
grep -qE 'Interactive Elixir \(1\.20' "$log" && ok "IEx banner (Elixir 1.20)" || bad "no IEx banner"
grep -qE 'iex\([^)]*\)[0-9]*>'        "$log" && ok "IEx prompt"                || bad "no IEx prompt"
grep -qE '^(iex\([^)]*\)[0-9]*> )?3$'  "$log" && ok "evaluated 1 + 2"           || bad "1 + 2 not evaluated"
grep -qE '(^|> )otp=29$'               "$log" && ok "OTP 29"                    || bad "otp_release != 29"

if grep -q 'uptime' "$log"; then
  echo "  info: kernel entry -> /init: $(grep -o 'uptime [0-9.]* s' "$log" | head -1)"
fi

echo
if [ $fail -eq 0 ]; then echo "SMOKE $LABEL: PASS"; else echo "SMOKE $LABEL: FAIL (logs in $LOGDIR)"; fi
exit $fail
