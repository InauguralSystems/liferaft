---
name: Bug Report
about: Report a bug in liferaft — a nondeterminism, an invariant violation, or a replay divergence
title: ""
labels: bug
assignees: ""
---

**Describe the bug**
What went wrong — e.g. the same seed produced different output across two runs,
one of the seven invariants was violated, `EIGS_TRACE`/`EIGS_REPLAY` diverged
byte-for-byte, or the sweep's minimal-repro reporting misfired.

**To reproduce**
The exact seed and step count (determinism is the contract — a bug should be a
runnable command):
```sh
eigenscript liferaft.eigs --seed N --steps M [--adversary] [--replay tape]
# or the sweep:
eigenscript liferaft_sweep.eigs --seeds N --steps M [--fault uptodate]
```

**Expected vs actual**
What you expected (byte-identical replay / all invariants holding) vs what
happened (include the divergence or the `VIOLATION` line).

**Environment**
- OS: [e.g., Ubuntu 24.04]
- EigenScript version: [output of `eigenscript --version`]
- liferaft version/tag: [e.g. v0.1.0]

> If the root cause is the EigenScript language, runtime, or an observer
> predicate itself, it belongs in the
> [EigenScript repo](https://github.com/InauguralSystems/EigenScript/issues) —
> and it's likely worth a note in [FINDINGS.md](../../FINDINGS.md).
