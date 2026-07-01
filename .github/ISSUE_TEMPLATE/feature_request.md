---
name: Feature Request
about: Suggest a new fault mode, invariant, or Raft extension to exercise
title: ""
labels: enhancement
assignees: ""
---

**What would this exercise?**
liferaft is a deterministic simulation tester: it stresses the EigenScript
runtime by driving a whole simulated Raft cluster from one integer seed. A good
feature deepens that stress — a new **fault mode** (network partition,
byzantine reordering, clock skew), a new **invariant** to check every step, or a
**Raft extension** like log snapshotting or membership changes.

**Proposed feature**
What it models and how it'd run (which flags / seeds), and how determinism is
preserved (all randomness must still flow through the one seeded PRNG).

**How it's checked**
Which invariant(s) or oracle would catch a regression, and how a failure would
shrink to a minimal reproducing `(seed, steps)`.

**Alternatives considered**
Any existing fault mode or invariant that already covers part of this.
