# Security Policy

This document covers supported versions and vulnerability reporting.

## Supported versions

Until `1.0.0`, `ocaml-agent-graph` is maintained as a fast-moving early-stage
project.

| Version line | Supported |
| --- | --- |
| `main` | Yes |
| Latest tagged release | Yes, once tags exist |
| Older commits and ad-hoc forks | No |

## Reporting a vulnerability

Please do not open a public issue for security vulnerabilities.

Preferred channel:

1. Use GitHub Private Vulnerability Reporting for this repository if it is enabled.

Fallback channel:

1. Contact the maintainer privately on GitHub: `@Louis-Ph`.
2. Include the affected graph path, agent/client surface, impact, reproduction steps, and any sanitized logs or config.
3. State whether the issue is already known publicly.

## Response targets

- initial acknowledgement within 5 business days
- status update after triage when the report is actionable
- coordinated disclosure after a fix or mitigation is available

## Scope guidance

The most security-sensitive areas in this repository currently include:

- BulkheadLM authorization and route access propagation
- terminal local operations and command execution boundaries
- graph runtime retries, timeouts, and agent orchestration flow
- configuration loading and path resolution
- SSH-oriented terminal wrappers

## Operational note

If you run this repository in a regulated or high-assurance environment, review
the graph runtime config, the client config, and the sibling `bulkhead-lm`
security posture together before deployment.
