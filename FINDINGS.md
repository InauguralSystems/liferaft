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

## F1 — `load_file` silently accepts a parse error that direct execution rejects (a discarded assignment) — FIXED (EigenScript PR #245, merged `021c23d`)

**Fix:** `load_file` now checks `g_parse_errors` after parsing and raises a
catchable `load_file: parse error in '<path>'` instead of running a partial AST,
matching `eval`/`import`. Turning the check on immediately caught a latent bug it
had been masking — `lib/lab.eigs` used the reserved keyword `stable` as a
variable, so `stable is 0/1` were silently-dropped parse errors (renamed to
`stable_flag`). Two silent parser error sites also now print a line number. The
dangerous half of F1 (silent acceptance) is resolved and behavior is now
consistent everywhere; expression-rooted lvalues remain unsupported but fail
cleanly in both paths (a feature, not a bug — out of scope). Original report
below.


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

## F4 — observed `loop while` silently truncated the DST's loops (global-observer convergence-halt) — FIXED (EigenScript PR #247, merged `a17d983`)

**Severity: high — the deepest finding.** Surfaced while benchmarking against the
Go original. The benchmark numbers were nonsense (EigenScript appeared *faster*
than compiled Go), and chasing that exposed that the sim's outcome was not a pure
function of the seed: same seed, same params, `committed` came out **6 / 8 / 12 /
21** depending only on how much unrelated read-only work ran per step.

**Root cause (in EigenScript, not liferaft):** every observed `loop while`
emitted `OP_LOOP_STALL_CHECK`, which auto-exited the loop when the **global**
`g_last_observer` showed convergence for ~100 iterations — including plain
counting loops. Because the observer is global, the DST's driving loops
(`loop while step < max_steps`, `loop while not sched_empty`) were halted by
whatever value the loop body — or a function it called — last assigned. A bounded
`loop while step < 1000` **halted at step 146** while the cluster was still
actively committing (`committed=6` at the halt, `21` if allowed to finish). The
invariants still passed (a truncated run is a valid Raft prefix), so it was
invisible until the benchmark leaned on long loops.

The diagnosis ruled out, in order: JIT (reproduced JIT-off), `NUM_REUSE`
arithmetic (disabled it, no change), the number freelist + a premature-free UAF
(disabled the freelist, ASan-clean), before landing on the loop-halting
semantics. The `100` threshold was a prototype constant that ossified into
load-bearing semantics and was never revisited.

**Fix (upstream):** convergence-halting is now **opt-in** — only a loop whose
condition references a predicate (`loop while not converged`) gets the
observer-stall; plain loops get a cap-only check. Compositional again. The
liferaft loops are all plain, so **the port needed no `unobserved` workaround** —
fixing the language fixed the consumer for free.

**Minimal repro** (no sim needed — any plain loop whose body settles the global
observer): the loop's iteration count changes with unrelated assignments, and
`__loop_exit__` reads `"stalled"` on a bounded loop that can't be
non-terminating. Pre-fix only. See EigenScript `tests/test_loop_halting.sh`.

## Methodology note — the adversary caught a harness bug (not a runtime bug)

Recorded because it shows the loop working. The moment the M3 network adversary
turned on, the applied-stream safety check fired immediately:
`applied conflict between 1 and 4 at 51: 'cmd:53' vs 'cmd:2'`. The signature —
an *early* command (`cmd:2`) at a *late* index — pointed away from Raft and at
the observation layer: when a node crashes and restarts, its state machine
resets (`applied_length = 0`) and legitimately *re-applies* its committed log,
but the harness's `cluster.applied[id]` list kept appending, so the re-application
read as a conflict. Fix: reset `cluster.applied[cid]` on restart (the state
machine is rebuilt from the log; Raft guarantees the rebuilt prefix matches).
After the fix, 40 seeds × 600 steps of full chaos run clean. No EigenScript or
protocol bug — a modeling error in the checker, surfaced exactly as intended.

## Positive result — M1, M2 & M3 workloads are ASan-clean

Not a bug, recorded for the record: the simulation runs **clean under
AddressSanitizer + LeakSanitizer + UBSan** — no leaks, no UBSan reports, no
refcount cycles — across the shapes most likely to surface runtime memory bugs.

- **M1** (long-lived cluster graph + churning event heap): 15 seeds x 200
  steps, a 500-step / 5-node run, and the `EIGS_TRACE` long-lived-tape path.
- **M2** (adds growing per-node logs + apply-result churn): a 800-step /
  5-node / apply-every-4 run (185 commands submitted, 183 committed on every
  node) plus 12 seeds x 300 steps with applies.
- **M3** (adds the adversary: crash/restart `new_raft` churn, log-restore,
  heap `drop_to` filtering, message duplication): a 2000-step / 5-node full-chaos
  run (355 submitted, 351 committed on every node, several re-elections) plus
  10 seeds x 600 steps of chaos.
- **M4** (adds the sweep: repeated cluster create/teardown across seeds + the
  violation/`exit` path): 15 seeds x 500 steps clean-sweep churn plus the
  fault-injection abort path — no leaks across cluster lifetimes.

The runtime's refcount + cycle-collector discipline holds for these allocation
patterns. Re-checked after every milestone.
