# liferaft (EigenScript)

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
| `src/scheduler.eigs` | deterministic discrete-event scheduler (priority queue) *(WIP)* |
| `src/invariants.eigs` | the seven TLA+-derived invariants *(WIP)* |
| `src/cluster.eigs` | in-memory cluster + network adversary *(WIP)* |
| `liferaft.eigs` | CLI runner *(WIP)* |
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

The CLI (once complete): `eigenscript liferaft.eigs --seed N --steps M [--replay tape]`.

## Status

**Milestone 1 complete** — leader election, 3 nodes, no adversary, one seed,
all seven invariants checked every step, byte-for-byte replay working. Verified
by `test/run.sh`: PRNG determinism, scheduler heap, state-machine election unit
tests, a 3-node integration run, same-seed two-process determinism (5 seeds),
`EIGS_TRACE`/`EIGS_REPLAY` byte-for-byte replay (zero nondet builtins), and a
50-seed × 200-step sweep with all seven invariants holding.

Next milestones: **M2** log replication (client applies + commit), **M3**
network adversary (latency, reorder, duplication, crash/restart, all from the
one seed), **M4** multi-seed chaos sweep with minimal-reproducing-seed reporting.

## Scope

In: pure in-process deterministic simulation. Out: real networking, disk
persistence, the KV-store CLI, and Maelstrom/Jepsen integration.
