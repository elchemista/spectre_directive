# Security policy

Spectre Directive treats reasoner output and mission information as untrusted
data. Executable targets must cross an explicit host-controlled resolution
boundary; applications remain responsible for authorization, secrets,
sandboxing, network access, and side effects.

## Supported versions

Until `1.0.0`, security fixes are provided for the latest published `0.x`
minor line.

| Version | Supported |
| --- | --- |
| `0.1.x` | Yes |
| Older pre-release snapshots | No |

## Reporting a vulnerability

Please use the repository's
[private security advisory form](https://github.com/elchemista/spectre_directive/security/advisories/new)
when available. If private reporting is unavailable, contact the maintainer
through GitHub first and do not include exploit details in a public issue.

Include the affected version, a minimal reproduction, the expected impact, and
any known mitigation. Please allow time for a fix and coordinated disclosure
before publishing details.

## Scope notes

Reports are especially useful when they involve:

- execution of an invocation target that the host did not explicitly trust;
- stale or mismatched responses mutating a newer mission state;
- callback failures escaping the supervised worker boundary;
- unsafe inclusion of executable values in provider-facing context;
- cross-mission information or state leakage.

Model prompt injection, unsafe application callbacks, and overly permissive
host policy are important concerns, but a report should identify a Directive
contract violation rather than only untrusted model behaviour.
