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
unit "scheduler heap"        test/test_scheduler.eigs "scheduler: all passed"
unit "raft state machine"    test/test_raft_unit.eigs "raft unit: all passed"
unit "m1 integration"        test/test_m1.eigs        "m1: all passed"
unit "m2 log replication"    test/test_m2.eigs        "m2: all passed"
unit "m3 network adversary"  test/test_m3.eigs        "m3: all passed"

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

echo "--- adversary sweep (chaos: latency/reorder/drop/dup/crash, invariants every step) ---"
asweep_ok=1
for s in $(seq 1 40); do
  out="$("$EIGS" liferaft.eigs --seed "$s" --steps 600 --nodes 5 --apply-period 6 --adversary --quiet 2>/dev/null)"
  if printf '%s\n' "$out" | grep -q "^VIOLATION"; then
    echo "FAIL: $(printf '%s\n' "$out" | grep '^VIOLATION')"; asweep_ok=0; fail=1
  fi
done
[ "$asweep_ok" -eq 1 ] && echo "PASS: adversary sweep (40 seeds x 600 steps, 5 nodes)"

echo "---"
if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "SOME FAILED"; fi
exit "$fail"
