#!/usr/bin/env bash
# Full liferaft test suite. Honors $EIGS (default ./eigs). Run from anywhere.
set -uo pipefail
cd "$(dirname "$0")/.."
EIGS="${EIGS:-./eigs}"
fail=0

unit () { # name file marker
  local out; out="$("$EIGS" "$2" 2>/dev/null)"
  if printf '%s\n' "$out" | grep -q -- "$3"; then
    echo "PASS: $1"
  else
    echo "FAIL: $1"; printf '%s\n' "$out" | tail -5; fail=1
  fi
}

echo "--- unit tests ---"
unit "prng determinism"      test/test_prng.eigs      "prng: all passed"
unit "task delivery layer"   test/test_tasknet.eigs   "tasknet: all passed"
unit "raft state machine"    test/test_raft_unit.eigs "raft unit: all passed"
unit "m1 integration"        test/test_m1.eigs        "m1: all passed"
unit "m2 log replication"    test/test_m2.eigs        "m2: all passed"
unit "m3 network adversary"  test/test_m3.eigs        "m3: all passed"
unit "viz event sink"        test/test_viz.eigs       "viz: all passed"

echo "--- determinism (same seed, two fresh processes) ---"
det_ok=1
for s in 1 7 42 12345 99999; do
  a="$("$EIGS" liferaft.eigs --seed "$s" --steps 150 2>/dev/null)"
  b="$("$EIGS" liferaft.eigs --seed "$s" --steps 150 2>/dev/null)"
  [ "$a" = "$b" ] || { echo "FAIL: determinism seed=$s diverged"; det_ok=0; fail=1; }
done
[ "$det_ok" -eq 1 ] && echo "PASS: determinism (5 seeds x 150 steps, byte-identical)"

echo "--- replay (EIGS_TRACE / EIGS_REPLAY) ---"
if bash test/replay.sh 12345 150; then echo "PASS: replay"; else echo "FAIL: replay"; fail=1; fi

echo "--- invariant sweep (all seven invariants, every step) ---"
sweep_ok=1
for s in $(seq 1 50); do
  out="$("$EIGS" liferaft.eigs --seed "$s" --steps 200 --quiet 2>/dev/null)"
  if printf '%s\n' "$out" | grep -q "^VIOLATION"; then
    echo "FAIL: $(printf '%s\n' "$out" | grep '^VIOLATION')"; sweep_ok=0; fail=1
  fi
done
[ "$sweep_ok" -eq 1 ] && echo "PASS: invariant sweep (50 seeds x 200 steps)"

echo "--- determinism UNDER ADVERSARY (chaos must still reproduce from the seed) ---"
adet_ok=1
for s in 1 7 42 31415 99999; do
  a="$("$EIGS" liferaft.eigs --seed "$s" --steps 400 --adversary --quiet 2>/dev/null)"
  b="$("$EIGS" liferaft.eigs --seed "$s" --steps 400 --adversary --quiet 2>/dev/null)"
  [ "$a" = "$b" ] || { echo "FAIL: adversary determinism seed=$s diverged"; adet_ok=0; fail=1; }
done
[ "$adet_ok" -eq 1 ] && echo "PASS: adversary determinism (5 seeds x 400 steps, byte-identical)"

echo "--- viz event stream (#18 slice 1: deterministic records, pure reader) ---"
# (a) Same seed, two fresh processes: the record stream itself must be
# byte-identical, non-empty, and carry the expected event kinds.
viz_ok=1
va="$("$EIGS" liferaft.eigs --seed 42 --steps 300 --adversary --quiet --viz-events 2>/dev/null)"
vb="$("$EIGS" liferaft.eigs --seed 42 --steps 300 --adversary --quiet --viz-events 2>/dev/null)"
[ "$va" = "$vb" ] || { echo "FAIL: viz record stream diverged across two runs"; viz_ok=0; fail=1; }
nviz="$(printf '%s\n' "$va" | grep -c '^VIZ ')"
[ "$nviz" -gt 0 ] || { echo "FAIL: viz run produced no VIZ records"; viz_ok=0; fail=1; }
for k in recv send vote election_start election_won append commit apply client_apply drop dup; do
  # No `grep -q`: under pipefail an early-exit grep SIGPIPEs the printf on a
  # stream this long and the pipeline reports failure despite the match.
  printf '%s\n' "$va" | grep "^VIZ .* kind=$k " >/dev/null \
    || { echo "FAIL: viz stream missing kind=$k"; viz_ok=0; fail=1; }
done
[ "$viz_ok" -eq 1 ] && echo "PASS: viz records deterministic + expected kinds ($nviz records)"
# (b) Pure-reader oracle: recording must not perturb the sim — the non-VIZ
# output of a --viz-events run is byte-identical to the same run without it
# (VIZ lines print strictly after the normal output).
pure_ok=1
for args in "--seed 7 --steps 150" "--seed 42 --steps 300 --adversary --quiet"; do
  # shellcheck disable=SC2086
  plain="$("$EIGS" liferaft.eigs $args 2>/dev/null)"
  # shellcheck disable=SC2086
  withviz="$("$EIGS" liferaft.eigs $args --viz-events 2>/dev/null | grep -v '^VIZ ')"
  [ "$plain" = "$withviz" ] \
    || { echo "FAIL: viz recording perturbed the sim ($args)"; pure_ok=0; fail=1; }
done
[ "$pure_ok" -eq 1 ] && echo "PASS: viz pure-reader oracle (recording leaves the run byte-identical)"

echo "--- M4 chaos sweep + minimal-reproducing-seed reporting ---"
# Fault OFF: the correct port must survive the whole sweep clean.
out="$("$EIGS" liferaft_sweep.eigs --seeds 40 --steps 600 2>/dev/null)"
if printf '%s\n' "$out" | grep -q '^SWEEP CLEAN'; then
  echo "PASS: M4 sweep clean ($(printf '%s\n' "$out" | grep '^SWEEP CLEAN' | sed 's/SWEEP CLEAN: //'))"
else
  echo "FAIL: M4 clean sweep"; printf '%s\n' "$out" | tail -3; fail=1
fi
# Fault ON: the oracle + minimizer must catch a real violation AND verify the
# minimal repro. A sweep that can never fail would prove nothing about detection.
out="$("$EIGS" liferaft_sweep.eigs --seeds 40 --steps 600 --fault uptodate 2>/dev/null)"
if printf '%s\n' "$out" | grep -q '^VIOLATION FOUND' && printf '%s\n' "$out" | grep -q 'verified=1'; then
  echo "PASS: M4 fault injection caught + minimal repro verified ($(printf '%s\n' "$out" | grep '^VIOLATION FOUND' | sed 's/VIOLATION FOUND //'))"
else
  echo "FAIL: M4 fault injection not caught/verified"; printf '%s\n' "$out" | tail -4; fail=1
fi

echo "---"
if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "SOME FAILED"; fi
exit "$fail"
