# Changelog

All notable changes to Spectre Directive are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Made distribution GitHub-only by removing Hex package metadata, publishing
  instructions, and package build CI.
- Replaced the dynamic Spectre source selector with one direct dependency on
  the Spectre GitHub `0.2.0` tag.

## [0.2.0] - 2026-08-01

### Changed

- Raised the package and Stack compatibility contracts to Spectre 0.2.0.
- Verified the pure loop, optional runtime, persisted turn handler, and
  Instance integration against the Spectre 0.2.0 operational runtime.

### Compatibility

- Kept the 0.1.6 Directive snapshot fixture as a permanent recovery contract.
- Directive remains a passive package boundary and does not duplicate core
  Work, Vigil, Run, or Instance ownership.

## [0.1.6] - 2026-07-31

### Changed

- Established a recoverable consolidation baseline with an explicit normative
  public API manifest and uniform release documentation.
- Added no runtime functionality and made no intentional breaking API change.

## [0.1.5] - 2026-07-30

### Changed

- Raised the package and Stack compatibility contract to Spectre 0.1.5.
- Verified that Directive remains a passive turn handler while the core
  Instance owns independent Effect and policy lifecycle for every retained
  Run.

## [0.1.4] - 2026-07-30

### Changed

- Updated the package, development source, and Stack compatibility contract
  for Spectre 0.1.4.
- Documented `Spectre.Instance` as the core owner of subject-scoped Agent
  State, multi-Run scheduling, and in-flight Invocations.

### Added

- Agent Instance conformance coverage proving that passive Directive
  installations can participate in multiple core Runs without starting a
  second scheduler or placing Directive runtime data in Agent State.

### Not included

- Core Run persistence, passivation, recovery, timers, leases, Ledger, Outbox,
  and Delivery Receipts remain part of the later continuity-plane phase.

## [0.1.3] - 2026-07-29

### Changed

- Made the Spectre turn handler an explicit `turn_handler: true` installation
  option. Directive's standalone mission engine is no longer inserted into
  every Stack-bound Agent and never acts as a second `Spectre.Run` executor.
- Updated the package contract and development dependency to Spectre 0.1.3.

### Added

- A versioned `Spectre.Stack.Installable` facade with immutable `store`,
  `clock`, and `resident_runs` declarations and no implicit runtime ownership.
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

[Unreleased]: https://github.com/elchemista/spectre_directive/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/elchemista/spectre_directive/compare/v0.1.6...v0.2.0
[0.1.6]: https://github.com/elchemista/spectre_directive/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/elchemista/spectre_directive/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/elchemista/spectre_directive/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/elchemista/spectre_directive/compare/v0.1.0...v0.1.3
[0.1.0]: https://github.com/elchemista/spectre_directive/releases/tag/v0.1.0
