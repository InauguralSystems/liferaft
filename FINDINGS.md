# FINDINGS

EigenScript bugs, nondeterminism sources, and performance cliffs exposed by
porting liferaft. Each entry has a minimal repro. This file is a primary
deliverable — the whole point of the port is to stress the runtime, so a
finding is a success, not a distraction.

Status legend: **OPEN** (needs an upstream decision/fix) · **WORKED-AROUND**
(port avoids it; upstream fix still wanted) · **FIXED** (upstream PR merged) ·
**BY-DESIGN** (documented language behavior; recorded so the next porter
doesn't relearn it).

---

## F1 — `load_file` silently accepts a parse error that direct execution rejects (a discarded assignment) — OPEN

**Severity: high.** An unsupported lvalue — assigning to a field of a
function-call result, `(call).field is X` — is a **parse error** when the file
is run directly (the program aborts, correctly). But the *same source*
executed through `load_file` is **silently accepted**: no error, the statement
runs, and **the assignment is discarded** (the write never happens). A whole
class of malformed statements in a `load_file`'d module can therefore misbehave
silently instead of aborting.

This bit the port for real: `got_vote` originally wrote
`(raft_member of [raft, from]).voted_for is raft.id`. Under `load_file` it
no-op'd, so self-votes never recorded and elections silently failed to reach
quorum — no error, just wrong behavior.

Minimal repro:

```
# mod.eigs
define find(list, id) as:
    for m in list:
        if m.id == id:
            return m
    return null
define got(r) as:
    (find of [r.members, "1"]).voted_for is "X"
    return r
```
```
# direct.eigs  — same two defines, then:
r is {"members": [{"id": "1", "voted_for": ""}]}
got of r
print of f"voted_for='{r.members[0].voted_for}'"
```
```
# viaload.eigs
load_file of "mod.eigs"
r is {"members": [{"id": "1", "voted_for": ""}]}
got of r
print of f"voted_for='{r.members[0].voted_for}'"
```

- `eigenscript direct.eigs`  → `1 parse error(s) — aborting`
- `eigenscript viaload.eigs` → `voted_for=''`   (no error; write silently lost)

Two distinct bugs are entangled here, both worth fixing upstream:
1. **Expression-rooted lvalues** (`(expr).field is …`, presumably also
   `(expr)[i] is …`) are unsupported. That's a defensible limitation — but it
   should fail the *same way* everywhere.
2. **`load_file` does not surface parse errors** that the top-level parser
   catches, and an unparseable assignment degrades to a silent no-op instead
   of aborting. The discarded-write behavior is the dangerous part.

**Workaround in the port:** bind the call result to a name first, then assign
through the name — `voter is raft_member of [...]; voter.voted_for is raft.id`.
This is the idiomatic form regardless, so the port uses it everywhere.

---

## F2 — `prev` is a reserved word (temporal interrogative), unusable as an identifier — BY-DESIGN

`prev` is the temporal interrogative keyword (`prev of x`), so a variable named
`prev` doesn't work. In `send_heartbeat` the local `prev` (previous log entry)
failed with `undefined variable 'prev'` at the assignment line. Renamed to
`prev_entry`.

Recorded as a porting hazard, not a bug: the reserved set includes the
temporal/observer words (`prev`, `at`, `state_at`, `what`/`who`/`when`/
`where`/`why`/`how`, `converged`/`stable`/`improving`/`diverging`/
`oscillating`/`equilibrium`, `unobserved`). Avoid them as identifiers when
porting. The port's only collision was `prev`.

---

## F3 — `exit of N` ignores N and always exits 1 — OPEN (minor)

`exit of 3` halts execution (correctly) but the process exit code is **1**, not
3 — the argument is ignored. Repro: `print of "before"`; `exit of 3` →
`before`, exit code 1. Likely because the teardown-routing fix made `exit` go
through the error path unconditionally. The CLI only needs zero/nonzero, so
this doesn't block the port, but a caller that wants a specific exit code can't
get one. (Also unverified: whether `exit of 0` exits 0 or 1 — worth checking.)

---

## Positive result — M1 workload is ASan-clean

Not a bug, recorded for the record: the Milestone-1 workload — the long-lived
cluster object graph plus the churning event-queue heap, the shapes most likely
to surface refcount cycles or leaks — runs **clean under AddressSanitizer +
LeakSanitizer + UBSan** (15 seeds x 200 steps, a 500-step / 5-node run, and the
`EIGS_TRACE` long-lived-tape path: no leaks, no UBSan reports, no refcount
cycles). The runtime's refcount + cycle-collector discipline holds for this
allocation pattern so far. Re-checked after every milestone.
