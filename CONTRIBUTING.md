# Contributing to liferaft

Thanks for your interest. `liferaft` is a deterministic simulation tester (DST)
for the Raft consensus protocol, written entirely in
[EigenScript](https://github.com/InauguralSystems/EigenScript) and ported from
the Go project [`codekitchen/liferaft`](https://github.com/codekitchen/liferaft):
a forcing function that stresses the runtime along axes the rest of the
ecosystem doesn't touch (a fragmenting cluster object graph, a churning
event-queue heap, and byte-for-byte replay from one seed). See the
[README](README.md) for the intent.

## Setup

EigenScript is not vendored here. Either build it alongside this repo and point
the gitignored `./eigs` symlink at the binary, or open the repo in a
devcontainer / [Codespace](https://codespaces.new/InauguralSystems/liferaft)
(which builds the pinned EigenScript for you).

```sh
# local: build EigenScript from source, then
ln -sf /path/to/EigenScript/src/eigenscript ./eigs
./eigs test/test_prng.eigs           # a single self-test
bash test/run.sh                     # the full suite
```

CI runs `test/run.sh` in the pinned devcontainer on every push and PR.

## The discipline (what makes a good contribution here)

- **Determinism is the product.** Output must be a pure function of the integer
  seed — same seed ⇒ byte-identical run, in two fresh processes and under
  `EIGS_TRACE`/`EIGS_REPLAY`. That is the contract the whole DST rests on.
- **No nondeterminism.** All randomness flows through the one seeded PRNG
  (`src/prng.eigs`). No `random`, no clock, no nondet builtin, no bitwise ops,
  no ambient iteration-order dependence. If the trace tape ever contains an `N`
  record, something leaked.
- **Invariants checked every step.** The seven TLA+-derived invariants
  (`src/invariants.eigs`) hold at every simulation step; a violation should
  shrink to a minimal reproducing `(seed, steps)`.
- **Surface gaps, don't work around them.** When the runtime does something
  wrong or surprising (a nondeterminism leak, a perf cliff, a divergence from
  the Go reference), log it in [FINDINGS.md](FINDINGS.md) and file it upstream in
  [EigenScript](https://github.com/InauguralSystems/EigenScript) — that's half
  the point of this repo.

## Before you open a PR

- `bash test/run.sh` passes: unit tests, same-seed two-process determinism,
  replay, the invariant sweep, adversary determinism, and the M4 chaos sweep.
- Keep the prevailing style: `snake_case`, sectioned files with header comments,
  and a comment at every order-sensitive iteration site.

## Reporting bugs

Open an issue with the exact seed and step count so it's a runnable repro. For
security concerns see [SECURITY.md](SECURITY.md).
