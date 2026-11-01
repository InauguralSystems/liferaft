#!/usr/bin/env bash
# Language-level replay oracle: record a run to a tape with EIGS_TRACE, replay
# it with EIGS_REPLAY, and require byte-for-byte identical stdout. Because the
# sim touches no nondeterministic builtin, only argv and the tape format v7
# module-source records may appear as `N` records.
set -uo pipefail
cd "$(dirname "$0")/.."
EIGS="${EIGS:-./eigs}"
SEED="${1:-12345}"
STEPS="${2:-150}"

tape="$(mktemp)"; first="$(mktemp)"; second="$(mktemp)"; err="$(mktemp)"
trap 'rm -f "$tape" "$first" "$second" "$err"' EXIT

# Each leg must COMPLETE: exit 0 and end on the run's `OK seed=<SEED> ` line.
# Two legs that crash identically produce identical stdout, so the diff below
# alone would pass a broken run (hq#58: LR-DET-1).
leg_ok () { # name rc stdout-file
  local last; last="$(tail -n 1 "$3")"
  if [ "$2" -ne 0 ] || [[ "$last" != "OK seed=$SEED "* ]]; then
    echo "replay: FAILED — $1 leg did not complete (exit=$2, last line: ${last:-<none>})"
    tail -n 3 "$err" | sed 's/^/    stderr: /'
    exit 1
  fi
}

EIGS_TRACE="$tape"  "$EIGS" liferaft.eigs --seed "$SEED" --steps "$STEPS" 2>"$err" > "$first"
leg_ok record "$?" "$first"
EIGS_REPLAY="$tape" "$EIGS" liferaft.eigs --seed "$SEED" --steps "$STEPS" 2>"$err" > "$second"
leg_ok replay "$?" "$second"

if ! diff -q "$first" "$second" >/dev/null; then
  echo "replay: FAILED — record vs replay output differs (seed=$SEED)"
  diff "$first" "$second" | head
  exit 1
fi

# The CLI reads argv once (#471). Tape v7 also records loaded module source;
# allow exactly those two source kinds, never simulation time or randomness.
nrec="$(grep -c '^N ' "$tape" 2>/dev/null || true)"
nargs="$(grep -Ec '^N ([0-9]+ )?args=' "$tape" 2>/dev/null || true)"
nsrc="$(grep -Ec '^N ([0-9]+ )?load_file_source(_chunk)?=' "$tape" 2>/dev/null || true)"
if [ "${nargs:-0}" -ne 1 ] || [ "${nrec:-0}" -ne "$((nargs + nsrc))" ]; then
  echo "replay: FAILED — tape carries $nrec nondeterministic builtin value(s);"
  echo "         expected args=1 plus module source only; got args=$nargs source=$nsrc"
  exit 1
fi

echo "replay: byte-for-byte identical, tape N-records=$nrec (args=$nargs source=$nsrc; sim determinism is purely seed-derived)"
