#!/usr/bin/env bash
# Language-level replay oracle: record a run to a tape with EIGS_TRACE, replay
# it with EIGS_REPLAY, and require byte-for-byte identical stdout. Because the
# sim touches no nondeterministic builtin, the tape must additionally carry ZERO
# `N` records — that is the assertion that nothing nondeterministic crept in.
set -uo pipefail
cd "$(dirname "$0")/.."
EIGS="${EIGS:-./eigs}"
SEED="${1:-12345}"
STEPS="${2:-150}"

tape="$(mktemp)"; first="$(mktemp)"; second="$(mktemp)"
trap 'rm -f "$tape" "$first" "$second"' EXIT

EIGS_TRACE="$tape"  "$EIGS" liferaft.eigs --seed "$SEED" --steps "$STEPS" 2>/dev/null > "$first"
EIGS_REPLAY="$tape" "$EIGS" liferaft.eigs --seed "$SEED" --steps "$STEPS" 2>/dev/null > "$second"

if ! diff -q "$first" "$second" >/dev/null; then
  echo "replay: FAILED — record vs replay output differs (seed=$SEED)"
  diff "$first" "$second" | head
  exit 1
fi

nrec="$(grep -c '^N ' "$tape" 2>/dev/null || true)"
if [ "${nrec:-0}" -ne 0 ]; then
  echo "replay: FAILED — tape carries $nrec nondeterministic builtin value(s);"
  echo "         determinism is not purely seed-derived (a nondet builtin crept in)."
  exit 1
fi

echo "replay: byte-for-byte identical, tape N-records=0 (determinism is purely seed-derived)"
