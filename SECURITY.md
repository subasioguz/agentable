# Security

Agentable stands between coding agents and databases, so security reports are welcome and taken
seriously.

## Reporting a vulnerability

Please report privately through GitHub's private vulnerability reporting on this repository
(Security tab, "Report a vulnerability"). Do not open a public issue for a vulnerability.

Include what an attacker can do, the steps to reproduce, and the version or commit. You will get an
answer within a week. Fixes for confirmed issues are released before the details are published,
and reporters are credited unless they ask not to be.

## What counts

Anything that lets an agent, or anyone who controls what an agent sends, get past the layers
described in [docs/PLAN.md](docs/PLAN.md#safety-model). For example:

- running a write where the connection allows only reads, or changing production without a person
- reading a hidden table, or a masked column unmasked
- getting a password, or connection details beyond the name and location
- applying a proposal, raising access or removing a rule without the device-owner confirmation
- requests that do not appear in the audit log

Known limits are listed in the plan: text classification alone cannot stop side-effecting
functions inside a `SELECT`, which is why read-only sessions and a SELECT-only database role sit
underneath it.
