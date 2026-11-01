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

# sim LABEL ARGS... : run `liferaft.eigs ARGS` and leave its stdout in $sim_out.
# Succeeds only for a COMPLETED run: exit status 0 AND the last non-VIZ line is
# the run's own `OK seed=<seed> ` completion line. Anything else — a VIOLATION
# (exit 1), a runtime error, an empty run — prints a FAIL with the exit status,
# the last line and the stderr tail, and returns 1. Comparing two outputs, or
# grepping one for the absence of a VIOLATION line, says nothing about a run
# that crashed: two runs dying identically at the same step are byte-identical,
# and a crash prints no VIOLATION (hq#58: LR-SWEEP-1, LR-DET-1).
sim_err="$(mktemp)"
trap 'rm -f "$sim_err"' EXIT
sim () {
  local label="$1"; shift
  local seed="" prev="" a rc last
  for a in "$@"; do [ "$prev" = "--seed" ] && seed="$a"; prev="$a"; done
  sim_out="$("$EIGS" liferaft.eigs "$@" 2>"$sim_err")"; rc=$?
  last="$(printf '%s\n' "$sim_out" | grep -v '^VIZ ' | tail -n 1)"
  if [ "$rc" -eq 0 ] && [ -n "$seed" ] && [[ "$last" == "OK seed=$seed "* ]]; then
    return 0
  fi
  echo "FAIL: $label: run did not complete (exit=$rc, last line: ${last:-<none>})"
  tail -n 3 "$sim_err" | sed 's/^/    stderr: /'
  return 1
}

echo "--- unit tests ---"
unit "prng determinism"      test/test_prng.eigs      "prng: all passed"
unit "task delivery layer"   test/test_tasknet.eigs   "tasknet: all passed"
unit "raft state machine"    test/test_raft_unit.eigs "raft unit: all passed"
unit "m1 integration"        test/test_m1.eigs        "m1: all passed"
unit "m2 log replication"    test/test_m2.eigs        "m2: all passed"
unit "m3 network adversary"  test/test_m3.eigs        "m3: all passed"
unit "viz event sink"        test/test_viz.eigs       "viz: all passed"
unit "invariant plants (oracle can go red)" test/test_invariant_plants.eigs "invariant plants: all passed"

echo "--- determinism (same seed, two fresh processes) ---"
det_ok=1
for s in 1 7 42 12345 99999; do
  sim "determinism seed=$s (run 1)" --seed "$s" --steps 150 || { det_ok=0; fail=1; continue; }
  a="$sim_out"
  sim "determinism seed=$s (run 2)" --seed "$s" --steps 150 || { det_ok=0; fail=1; continue; }
  b="$sim_out"
  [ "$a" = "$b" ] || { echo "FAIL: determinism seed=$s diverged"; det_ok=0; fail=1; }
done
[ "$det_ok" -eq 1 ] && echo "PASS: determinism (5 seeds x 150 steps, byte-identical)"

echo "--- replay (EIGS_TRACE / EIGS_REPLAY) ---"
if bash test/replay.sh 12345 150; then echo "PASS: replay"; else echo "FAIL: replay"; fail=1; fi

echo "--- invariant sweep (all seven invariants, every step) ---"
# Every seed must run to its OK line with exit 0: a VIOLATION exits 1 and is
# reported by sim with its VIOLATION line, and so is a crash.
sweep_done=0
for s in $(seq 1 50); do
  sim "invariant sweep seed=$s" --seed "$s" --steps 200 --quiet && sweep_done=$((sweep_done + 1))
done
if [ "$sweep_done" -eq 50 ]; then
  echo "PASS: invariant sweep (50 seeds x 200 steps, all 50 completed clean)"
else
  echo "FAIL: invariant sweep ($sweep_done of 50 seeds completed clean)"; fail=1
fi

echo "--- determinism UNDER ADVERSARY (chaos must still reproduce from the seed) ---"
adet_ok=1
for s in 1 7 42 31415 99999; do
  sim "adversary determinism seed=$s (run 1)" --seed "$s" --steps 400 --adversary --quiet || { adet_ok=0; fail=1; continue; }
  a="$sim_out"
  sim "adversary determinism seed=$s (run 2)" --seed "$s" --steps 400 --adversary --quiet || { adet_ok=0; fail=1; continue; }
  b="$sim_out"
  [ "$a" = "$b" ] || { echo "FAIL: adversary determinism seed=$s diverged"; adet_ok=0; fail=1; }
done
[ "$adet_ok" -eq 1 ] && echo "PASS: adversary determinism (5 seeds x 400 steps, byte-identical)"

echo "--- viz event stream (#18 slice 1: deterministic records, pure reader) ---"
# (a) Same seed, two fresh processes: the record stream itself must be
# byte-identical, non-empty, and carry the expected event kinds.
viz_ok=1
va=""; vb=""
if sim "viz record stream (run 1)" --seed 42 --steps 300 --adversary --quiet --viz-events; then va="$sim_out"; else viz_ok=0; fail=1; fi
if sim "viz record stream (run 2)" --seed 42 --steps 300 --adversary --quiet --viz-events; then vb="$sim_out"; else viz_ok=0; fail=1; fi
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
  sim "viz pure-reader plain ($args)" $args || { pure_ok=0; fail=1; continue; }
  plain="$sim_out"
  # shellcheck disable=SC2086
  sim "viz pure-reader --viz-events ($args)" $args --viz-events || { pure_ok=0; fail=1; continue; }
  withviz="$(printf '%s\n' "$sim_out" | grep -v '^VIZ ')"
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
  sim "visualizer CLI stream ($args)" $args --quiet --viz-events || { vfe_ok=0; fail=1; continue; }
  cli="$(printf '%s\n' "$sim_out" | grep '^VIZ ')"
  # shellcheck disable=SC2086
  dmp="$("$EIGS" visualizer_main.eigs $args --dump 2>/dev/null)"
  [ -n "$dmp" ] || { echo "FAIL: visualizer --dump produced nothing ($args)"; vfe_ok=0; fail=1; }
  [ "$cli" = "$dmp" ] \
    || { echo "FAIL: visualizer collection diverged from the CLI stream ($args)"; vfe_ok=0; fail=1; }
done
[ "$vfe_ok" -eq 1 ] && echo "PASS: visualizer collection byte-identical to the CLI viz stream"
# (b) Tape accounting: one argv N record (#471), plus only the two tape v7
# module-source kinds, exactly like the CLI (see replay.sh).
vtape="$(mktemp)"
EIGS_TRACE="$vtape" "$EIGS" visualizer_main.eigs --seed 7 --steps 150 --dump >/dev/null 2>&1
vn="$(grep -c '^N ' "$vtape" 2>/dev/null || true)"
va="$(grep -Ec '^N ([0-9]+ )?args=' "$vtape" 2>/dev/null || true)"
vs="$(grep -Ec '^N ([0-9]+ )?load_file_source(_chunk)?=' "$vtape" 2>/dev/null || true)"
rm -f "$vtape"
if [ "${va:-0}" -ne 1 ] || [ "${vn:-0}" -ne "$((va + vs))" ]; then
  echo "FAIL: visualizer dump tape carries N=$vn args=$va source=$vs (args=1 plus module source only expected)"
  fail=1
else
  echo "PASS: visualizer tape N-records=$vn (args=$va source=$vs)"
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
if printf '%s\n' "$out" | grep -q '^VIOLATION FOUND' && printf '%s\n' "$out" | grep -q 'verified=true'; then
  echo "PASS: M4 fault injection caught + minimal repro verified ($(printf '%s\n' "$out" | grep '^VIOLATION FOUND' | sed 's/VIOLATION FOUND //'))"
else
  echo "FAIL: M4 fault injection not caught/verified"; printf '%s\n' "$out" | tail -4; fail=1
fi
# The uptodate fault is a vote-check bug: the seven-invariant oracle must be
# what catches it. The applied-stream check also fires on it later, so without
# this a disabled check_invariants still passes the line above (hq#58:
# LR-ORACLE-1). Then the sweep's printed minimal repro, run through
# liferaft.eigs — the program the invariant sweep and determinism gates run —
# must stop at the same step with the same violation and exit 1: proof that
# the CLI's own oracle wiring can fail a run, not just the sweep driver's.
found="$(printf '%s\n' "$out" | grep '^VIOLATION FOUND ' | head -n 1)"
msg="${found#VIOLATION FOUND }"
repro="$(printf '%s\n' "$out" | grep -E '^  eigenscript liferaft\.eigs ' | head -n 1)"
repro_args="${repro#  eigenscript liferaft.eigs }"
if ! printf '%s\n' "$msg" | grep -Eq '^seed=[0-9]+ step=[0-9]+: (leader|log|log_prefix|election_safety|quorum_log|more_up_to_date|leader_completeness)_invariant: '; then
  echo "FAIL: M4 fault injection was not caught by the seven-invariant oracle (got: ${found:-<none>})"; fail=1
elif [ -z "$repro" ]; then
  echo "FAIL: M4 fault injection printed no liferaft.eigs repro command"; fail=1
else
  # shellcheck disable=SC2086
  cli_out="$("$EIGS" liferaft.eigs $repro_args --quiet 2>/dev/null)"; cli_rc=$?
  cli_last="$(printf '%s\n' "$cli_out" | tail -n 1)"
  if [ "$cli_rc" -eq 1 ] && [ "$cli_last" = "VIOLATION $msg" ]; then
    echo "PASS: M4 repro through liferaft.eigs fails the run (exit 1, $cli_last)"
  else
    echo "FAIL: M4 repro through liferaft.eigs ($repro_args): exit=$cli_rc, last line: ${cli_last:-<none>}; expected exit 1 and 'VIOLATION $msg'"; fail=1
  fi
fi

echo "---"
if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; else echo "SOME FAILED"; fi
exit "$fail"
