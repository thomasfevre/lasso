# Security policy

## Supported versions

The current release line, 0.1.x, receives security fixes.

## Reporting a vulnerability

Please use a private GitHub Security Advisory for this repository when one is
available. If private reporting is unavailable, contact the repository owner
through their GitHub profile rather than opening a public issue.

Do not include real credentials, screenshots, capture databases, or other
private user content in a report. A minimal reproduction with synthetic data is
enough to begin investigation.

## Scope

The most sensitive surfaces are the local capture store, MCP process, Chrome
Native Messaging bridge, and redaction path. Reports involving unintended data
disclosure, permission bypass, local privilege escalation, or a way to cause
Lasso to capture without a deliberate user action are especially useful.
