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

echo "--- visualizer front-end (#18 slice 3: pure reader of the run) ---"
# (a) Collection oracle: the visualizer's sim run must be byte-identical
# to the headless CLI's — `--dump` prints viz_collect's records in the
# CLI's exact VIZ line format, and both streams must match. This is what
# makes the UI a reader of THE run, not of a run like it. (No ui lib on
# this path, so it runs on the pinned CI binary too.)
vfe_ok=1
for args in "--seed 7 --steps 150" "--seed 42 --steps 300 --adversary"; do
  # shellcheck disable=SC2086
  cli="$("$EIGS" liferaft.eigs $args --quiet --viz-events 2>/dev/null | grep '^VIZ ')"
  # shellcheck disable=SC2086
  dmp="$("$EIGS" visualizer_main.eigs $args --dump 2>/dev/null)"
  [ -n "$dmp" ] || { echo "FAIL: visualizer --dump produced nothing ($args)"; vfe_ok=0; fail=1; }
  [ "$cli" = "$dmp" ] \
    || { echo "FAIL: visualizer collection diverged from the CLI stream ($args)"; vfe_ok=0; fail=1; }
done
[ "$vfe_ok" -eq 1 ] && echo "PASS: visualizer collection byte-identical to the CLI viz stream"
# (b) Tape accounting: the collection path stays argv-only nondet — one
# N record (#471), exactly like the CLI (see replay.sh).
vtape="$(mktemp)"
EIGS_TRACE="$vtape" "$EIGS" visualizer_main.eigs --seed 7 --steps 150 --dump >/dev/null 2>&1
vn="$(grep -c '^N ' "$vtape" 2>/dev/null || true)"
rm -f "$vtape"
if [ "${vn:-0}" -gt 1 ]; then
  echo "FAIL: visualizer dump tape carries $vn N-records (argv-only expected)"
  fail=1
else
  echo "PASS: visualizer tape N-records=$vn (argv only)"
fi
# (c) The UI itself, driven headlessly — dev-binary only until the
# timeline widget (#842) reaches a release pin; the probe SKIPs it on
# the v0.36.0 pin instead of failing CI.
if "$EIGS" test/probe_timeline.eigs >/dev/null 2>&1; then
  unit "visualizer UI (headless dispatch)" test/test_viz_ui.eigs "viz ui: all passed"
else
  echo "SKIP: visualizer UI (timeline widget not in this runtime's lib — dev binary only until the next release cut)"
fi

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
