# Security Policy

`liferaft` is a pure-EigenScript deterministic simulation tester for the Raft
consensus protocol. It opens no network sockets and takes no untrusted input —
it runs its own seeded simulation on the EigenScript interpreter. The realistic
attack surface is tiny, but reports are welcome.

## Reporting a vulnerability

Please report security issues privately rather than in a public issue — via
[GitHub private vulnerability reporting](https://github.com/InauguralSystems/liferaft/security/advisories/new)
or by contacting the maintainer at the address on the
[InauguralSystems](https://github.com/InauguralSystems) profile
(`contact@inauguralsystems.com`, subject prefix `[SECURITY]`). Include steps to
reproduce and the affected EigenScript version.

## Scope

- Issues in the EigenScript interpreter, runtime, or observer predicates belong
  in the [EigenScript](https://github.com/InauguralSystems/EigenScript)
  repository, which has its own security process.
- `liferaft`'s own scope is the `.eigs` simulation, the CLI runner, and the
  tests.

## Supported versions

The latest tag on `main` is supported. `liferaft` tracks a pinned EigenScript
version (see `.devcontainer/Dockerfile`'s `EIGS_REF`); run
against that or newer.
