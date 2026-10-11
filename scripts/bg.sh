#!/usr/bin/env bash
# bg.sh: run a long command detached and poll it with bounded waits, so that
# nothing (a human, an agent, CI) ever blocks on a 10-minute kernel lint.
#
#   scripts/bg.sh start NAME -- CMD [ARGS...]   start CMD in the background
#   scripts/bg.sh status [NAME]                 running/done + last log lines
#   scripts/bg.sh wait NAME [SECONDS]           poll up to SECONDS (default 60), never longer
#   scripts/bg.sh tail NAME [LINES]
#   scripts/bg.sh kill NAME                     kill the process tree and its docker containers
#   scripts/bg.sh clean                         remove records of finished jobs
#
# State lives in build/bg/NAME.{log,pid,exit}. Commands get BG_NAME in their
# environment; scripts that run docker should pass "--label bg.name=$BG_NAME"
# so `kill` can find the container (see scripts/aster-lint.sh).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR=${BG_DIR:-$ROOT/build/bg}
mkdir -p "$DIR"

now() { date +%s; }
alive() { kill -0 "$1" 2>/dev/null; }

status_one() {
  local name=$1 pid rc started elapsed state
  pid=$(cat "$DIR/$name.pid" 2>/dev/null || echo 0)
  started=$(cat "$DIR/$name.start" 2>/dev/null || now)
  if [ -f "$DIR/$name.exit" ]; then
    rc=$(cat "$DIR/$name.exit"); state="done rc=$rc"
    elapsed=$(( $(stat -f %m "$DIR/$name.exit") - started ))
  elif alive "$pid"; then
    state="running"; elapsed=$(( $(now) - started ))
  else
    state="died (no exit code)"; elapsed=$(( $(now) - started ))
  fi
  printf '%-14s %-18s %4ds\n' "$name" "$state" "$elapsed"
}

cmd=${1:-help}; shift || true
case $cmd in
start)
  name=$1; shift; [ "${1:-}" = -- ] && shift
  [ $# -gt 0 ] || { echo "bg: no command" >&2; exit 2; }
  if [ -f "$DIR/$name.pid" ] && alive "$(cat "$DIR/$name.pid")"; then
    echo "bg: $name is still running (pid $(cat "$DIR/$name.pid"))" >&2; exit 1
  fi
  rm -f "$DIR/$name.exit" "$DIR/$name.log"
  now > "$DIR/$name.start"
  # The wrapper records the exit code; nohup + & detaches it from this shell.
  BG_NAME=$name nohup bash -c '
    out=$1; shift
    "$@"; rc=$?
    echo "$rc" > "$out.exit"
    echo "[bg] exit $rc"
  ' bg-wrapper "$DIR/$name" "$@" > "$DIR/$name.log" 2>&1 &
  echo $! > "$DIR/$name.pid"
  echo "started $name (pid $!), log $DIR/$name.log"
  ;;
status)
  if [ $# -gt 0 ]; then status_one "$1"; tail -n 5 "$DIR/$1.log" 2>/dev/null | sed 's/^/  | /'
  else for f in "$DIR"/*.pid; do [ -f "$f" ] || continue; status_one "$(basename "${f%.pid}")"; done; fi
  ;;
wait)
  name=$1; max=${2:-60}; t0=$(now)
  while [ ! -f "$DIR/$name.exit" ] && [ $(( $(now) - t0 )) -lt "$max" ]; do
    alive "$(cat "$DIR/$name.pid" 2>/dev/null || echo 0)" || break
    sleep 5
  done
  status_one "$name"; tail -n 8 "$DIR/$name.log" 2>/dev/null | sed 's/^/  | /'
  [ -f "$DIR/$name.exit" ] && exit "$(cat "$DIR/$name.exit")" || exit 124
  ;;
tail) tail -n "${2:-40}" "$DIR/$1.log" ;;
kill)
  name=$1
  docker ps -q --filter "label=bg.name=$name" | xargs -r docker kill >/dev/null 2>&1 || true
  pid=$(cat "$DIR/$name.pid" 2>/dev/null || echo 0)
  if alive "$pid"; then pkill -TERM -P "$pid" 2>/dev/null || true; kill -TERM "$pid" 2>/dev/null || true; fi
  [ -f "$DIR/$name.exit" ] || echo 130 > "$DIR/$name.exit"
  status_one "$name"
  ;;
clean)
  for f in "$DIR"/*.exit; do [ -f "$f" ] || continue; n=${f%.exit}; rm -f "$n".{exit,log,pid,start}; done
  echo "cleaned"
  ;;
*) sed -n '2,15p' "$0" ;;
esac
