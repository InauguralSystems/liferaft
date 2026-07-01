## What does this PR do?

<!-- Brief description of the change -->

## Checklist

- [ ] **Determinism holds** — same seed ⇒ byte-identical output (two fresh
      processes; and `EIGS_TRACE`/`EIGS_REPLAY` replays byte-for-byte)
- [ ] All **seven invariants** hold every step (invariant sweep clean)
- [ ] `bash test/run.sh` passes locally
- [ ] Any runtime gap or surprising behavior is logged in
      [FINDINGS.md](../FINDINGS.md) (and, if it's an EigenScript bug, filed upstream)
- [ ] No nondeterministic builtin, clock, or ambient randomness introduced —
      output is a pure function of the seed
