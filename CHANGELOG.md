# Changelog

All notable changes to Spectre Directive are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `Spectre.Directive.Store` and versioned `Spectre.Directive.Snapshot` contracts
  for host-owned persistence of a complete mission and living plan.
- Store-backed Spectre Agent conversations that resume questions,
  confirmations, policy requests, and completion through ordinary Agent turns.
- Ordered `Spectre.Turn.Handler` integration that remains optional to both
  Spectre and Directive.
- `Spectre.Directive.Presenter` for channel-specific rendering while retaining
  the typed request or outcome in result metadata.
- Replay receipts keyed by a stable Spectre `turn_id`, preventing an ambiguous
  delivery retry from consuming the same Directive input twice.
- A runnable persisted-Agent example and expanded integration documentation for
  repeated questions, completion, Store concurrency, retries, and idempotency.

## [0.1.0] - 2026-07-23

### Added

- A pure, resumable mission-loop reducer with correlated requests and stale
  response protection.
- Authored, guided, and autonomous plan modes with atomic versioned plan
  patches.
- A reusable directive DSL for missions, steps, trusted invocations, policy
  requirements, and completion callbacks.
- An optional OTP runtime with one supervised state machine per mission and
  isolated callback workers.
- Host integrations for ordinary `GenServer` modules and optional
  `Spectre.Agent` modules.
- Provider-neutral reasoner, invoker, policy, and request-handler behaviours.
- Mission-local information, application assigns, lifecycle controls, event
  subscriptions, compact pulses, terminal outcomes, and causal traces.
- Conversational `await_input/2` and `reply/3` helpers for repeated Agent
  questions, confirmations, policy decisions, and terminal outcomes.
- A provider-neutral protocol description and safe context projection for LLM
  adapters.
- Runnable pure-loop, automatic-runtime, authored-DSL, and Spectre Agent
  integration examples.
- GitHub Actions checks for formatting, warning-free compilation, tests and
  coverage, non-strict Credo, and Dialyzer.

[Unreleased]: https://github.com/elchemista/spectre_directive/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/elchemista/spectre_directive/releases/tag/v0.1.0
