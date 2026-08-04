# liferaft (EigenScript)

[![CI](https://github.com/InauguralSystems/liferaft/actions/workflows/tests.yml/badge.svg)](https://github.com/InauguralSystems/liferaft/actions/workflows/tests.yml)
[![OpenSSF Scorecard](https://api.securityscorecards.dev/projects/github.com/InauguralSystems/liferaft/badge)](https://securityscorecards.dev/viewer/?uri=github.com/InauguralSystems/liferaft)
[![tag](https://img.shields.io/github/v/tag/InauguralSystems/liferaft?label=version)](https://github.com/InauguralSystems/liferaft/tags)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A deterministic simulation tester (DST) for the Raft consensus protocol,
written in [EigenScript](https://github.com/InauguralSystems/EigenScript) and
ported from the Go project [`codekitchen/liferaft`](https://github.com/codekitchen/liferaft).

This is **not** a polished Raft library. It is a workload that stresses the
EigenScript runtime along axes the rest of the ecosystem doesn't touch: a
long-lived, fragmenting object graph (a whole simulated cluster), a churning
event-queue heap under irregular insert/extract-min pressure, and a hard
**byte-for-byte replay** requirement across the entire cluster from a single
integer seed. Every divergence from the Go reference, and every leak of
nondeterminism, is a candidate EigenScript bug — logged in
[`FINDINGS.md`](FINDINGS.md), which is a primary deliverable.

## Determinism contract

- The whole simulation is reproducible from one integer **seed**.
- All randomness flows through **one** seeded PRNG (`src/prng.eigs`),
  implemented in pure double arithmetic — no `random`, no clock, no nondet
  builtin, no bitwise ops. Same seed ⇒ byte-identical run on any platform.
- Dict iteration order is deterministic in EigenScript (`keys of` is
  insertion-ordered), but anything order-sensitive iterates an explicit
  ordered list; each such site is commented.
- Two determinism checks: (a) the strong oracle — run a seed in two fresh
  processes and `diff` stdout; (b) the trace oracle — `EIGS_TRACE` then
  `EIGS_REPLAY` must replay byte-for-byte (and, since the sim uses no nondet
  builtin, the tape must contain zero `N` records — itself an assertion that
  nothing nondeterministic crept in).

## Layout

| Path | What |
|------|------|
| `src/prng.eigs` | seeded PRNG (the one source of randomness) |
| `src/raft.eigs` | the pure Raft state machine — `handle_event(raft, event) → updates` |
| `src/invariants.eigs` | the seven TLA+-derived invariants |
| `src/adversary.eigs` | seeded network adversary (latency/drop/dup/crash/reorder) |
| `src/cluster.eigs` | in-memory cluster harness on the runtime's cooperative task layer (a task per node, a detached deliverer task per in-flight message, virtual-clock latency, seeded-scheduler reorder) |
| `liferaft.eigs` | CLI runner |
| `visualizer.eigs` + `visualizer_main.eigs` | cluster visualizer — timeline UI + seed-replay scrubber over the viz event stream (#18) |
| `test/` | unit + determinism + replay tests |
| `FINDINGS.md` | every runtime bug / nondeterminism / perf cliff this port exposed |

## Running

Build EigenScript and point `eigs` at the binary (the repo ships a dev symlink,
gitignored):

```
ln -sf /path/to/EigenScript/src/eigenscript ./eigs
./eigs test/test_prng.eigs        # PRNG determinism self-test
./eigs test/test_raft_unit.eigs   # state-machine election unit tests
```

The CLI: `eigenscript liferaft.eigs --seed N --steps M [--replay tape]
[--viz-events]`. `--viz-events` turns on the engine's event-history sink and
prints one `VIZ t=.. node=.. kind=.. role=.. term=.. ...` line per recorded
event (elections, votes, appends, commits, sends/drops/dups, crash/restart)
after the normal output — the data contract for the #18 cluster visualizer.
The sink is a pure reader: the non-`VIZ` output is byte-identical to a run
without the flag (gated in `test/run.sh`), and an in-process front-end reads
the same history off `cluster.viz`.

### Cluster visualizer

`eigenscript visualizer_main.eigs --seed N --steps M [--nodes K] [--adversary]`
opens a timeline view of the run (gfx build required): one lane per node,
role spans (follower/candidate/leader), a marker per recorded event, and a
**seed-replay scrubber** — drag the time ruler and the per-node state panel
re-derives role/term at that instant from the recorded history. Because the
sim is a pure function of the seed, re-reading the record stream *is* the
byte-for-byte replay; `--dump` prints the collected stream in the CLI's `VIZ`
format and `test/run.sh` diffs it against `--viz-events` (so the UI can never
show a run that differs from the headless one). The timeline widget ships in
EigenScript's `lib/ui` on main (post-v0.36.0); on the pinned runtime the UI
test SKIPs and only the collection oracle runs.

## Status

**Milestones 1–4 complete** — the full DST. Verified by `test/run.sh`:
- **M1 leader election** — PRNG determinism, the task-based delivery layer,
  state-machine election unit tests, 3-node integration, same-seed two-process
  determinism, `EIGS_TRACE`/`EIGS_REPLAY` byte-for-byte (the only tape record
  is `args`' argv, by upstream contract).
- **M2 log replication** — client applies, commit propagation, applied-stream
  safety; commands replicate to every node; 50-seed × 200-step invariant sweep.
- **M3 network adversary** — latency, reordering, duplication, drops, and
  crash/restart, all from the one seed. Under full chaos the cluster still
  elects leaders (repeatedly), replicates, and commits hundreds of commands
  with all seven invariants + applied-stream safety holding every step.
  **Determinism holds under chaos**: same seed in two processes is byte-identical
  (5 seeds × 400 steps), and a 40-seed × 600-step × 5-node adversary sweep is
  clean. ASan-clean throughout (incl. crash/restart churn).

- **M4 chaos sweep + minimal-reproducing-seed reporting** (`liferaft_sweep.eigs`):
  sweeps seeds 1..N under the adversary, checking all invariants every step; on
  the first failure it reports the smallest failing seed and the first
  (minimal) violating step, then re-runs that exact `(seed, steps)` to **verify**
  the minimal repro and prints the runnable command. Validated both ways: the
  correct port sweeps clean (40 seeds × 600 steps), and an injected fault
  (`--fault uptodate`, a stale candidate winning — a real Raft safety bug) is
  caught and shrunk to a verified `--seed 1 --steps 75` repro.

The DST is complete. Possible extensions: snapshotting, membership changes,
larger automated sweeps in CI.

## Scope

In: pure in-process deterministic simulation. Out: real networking, disk
persistence, the KV-store CLI, and Maelstrom/Jepsen integration.
