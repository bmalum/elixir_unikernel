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
LABEL=$1; QEMU_CMD=$2; CMDLINE=$3
TIMEOUT=${SMOKE_TIMEOUT:-240}
LOGDIR=${SMOKE_LOGDIR:-build/logs}; mkdir -p "$LOGDIR"
TIMEOUT_BIN=timeout; command -v timeout >/dev/null || TIMEOUT_BIN=gtimeout
fail=0

ok()  { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=1; }
strip_ansi() { sed -e 's/\x1b\[[0-9;?]*[A-Za-z]//g' -e 's/\x1bc//g' -e 's/\r$//' "$1" > "$1.clean"; }

# run_vm <mode> <wait-for-regex> <input-to-type> <stop-regex>
# Starts QEMU with stdin from a FIFO; types <input> once <wait-for-regex> is
# seen on the console; stops when <stop-regex> appears or on timeout.
run_vm() {
  local mode waitre input stopre log fifo qpid typed t
  mode=$1; waitre=$2; input=$3; stopre=$4; log="$LOGDIR/$LABEL-$mode.log"
  fifo=$(mktemp -u); mkfifo "$fifo"
  : > "$log"
  $TIMEOUT_BIN "$TIMEOUT" $QEMU_CMD -append "$CMDLINE uniapp.mode=$mode" < "$fifo" > "$log" 2>&1 &
  qpid=$!
  exec 3>"$fifo"            # keep the FIFO open for writing
  typed=0; t=0
  while kill -0 $qpid 2>/dev/null && [ $t -lt "$TIMEOUT" ]; do
    sleep 1; t=$((t+1))
    if [ $typed -eq 0 ] && grep -qE "$waitre" "$log"; then
      sleep 2; printf '%s' "$input" >&3; typed=1
    fi
    if grep -qE "$stopre" "$log"; then sleep 2; break; fi
  done
  printf '\001x' >&3 2>/dev/null   # Ctrl-a x: quit QEMU
  exec 3>&-
  sleep 1; kill $qpid 2>/dev/null; wait $qpid 2>/dev/null
  rm -f "$fifo"
  strip_ansi "$log"
  echo "$log.clean"
}

echo "== $LABEL: app mode"
log=$(run_vm app 'PROBE done' '' 'PROBE done')
grep -q '\[init\] exec'        "$log" && ok "init exec'd beam.smp"   || bad "init did not exec beam.smp"
grep -q 'uniapp starting'      "$log" && ok "application started"    || bad "application did not start"
grep -q 'echo: listening'      "$log" && ok "gen_tcp listen"         || bad "gen_tcp listen"
for p in udp tcp tls_srv; do
  grep -q "PROBE $p ok" "$log" && ok "probe $p" || bad "probe $p: $(grep "PROBE $p" "$log" | head -1)"
done
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
