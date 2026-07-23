# Roadmap

Spectre Directive is intended to stay a small, embeddable mission-loop core.
This roadmap describes direction, not a delivery commitment. Priorities may
change as the library is used in real applications.

## 0.1 — Foundation

The `0.1.0` release establishes the core contracts:

- a pure state-passing engine with correlated external requests;
- authored, guided, and autonomous plan modes;
- atomic, versioned plan correction;
- trusted invocation and host-owned policy boundaries;
- an optional supervised OTP runtime;
- reusable directives and GenServer/Spectre Agent integration;
- explicit synchronous and event-driven user conversation boundaries;
- mission-local information, traces, lifecycle controls, and outcomes.

The release is intentionally pre-1.0. Public APIs are usable, but feedback may
still lead to breaking changes between minor versions.

## Near-term candidates

The next phase will focus on operating the existing model reliably rather than
expanding it into a general agent platform:

- adapter conformance helpers for Store revision checks and ambiguous delivery
  simulations;
- explicit receipt-retention and snapshot-compaction policies for long-running
  missions;
- telemetry events for request latency, callback execution, plan revisions,
  and terminal outcomes;
- compatibility testing across supported Elixir and Erlang/OTP combinations;
- clearer adapter test kits for custom reasoners, policies, invokers, and
  request handlers;
- additional examples for guided confirmation and host-driven manual runtime
  execution;
- continued tightening of public types, documentation, and error contracts.

## Longer-term exploration

These ideas require real-world evidence before they become commitments:

- opt-in durable runtime adapters built outside the pure engine;
- richer inspection and replay tooling over causal traces;
- distributed mission ownership and hand-off patterns;
- interoperability guides for tool-selection, memory, and retrieval systems.

## Ecosystem integration direction

Directive should participate in a shared Spectre turn vocabulary without
becoming the protocol, memory system, or capability executor:

- Spectre owns the local Agent turn and pre-route handler ordering;
- Directive owns mission/plan transitions and Store snapshots;
- SpectrePulse may own agent-to-agent envelopes, correlation, remote task
  lifecycle, retries, and delivery;
- SpectreMnemonic may supply memory through Spectre's memory boundary;
- SpectreLens may supply browser capabilities through trusted actions/Skills.

The current Store-backed handler is intentionally one-way: an active Directive
can claim a normal Agent input and return a typed reply. Future distributed
handoff should build on concrete Pulse task semantics and stable identities,
not expand the handler into a generic wire protocol or shared mutable state.

## Deliberate non-goals

The core is not planned to own:

- an LLM provider or model SDK;
- long-term memory, retrieval, or vector storage;
- a global tool registry or arbitrary code execution;
- application authorization policy;
- a mandatory persistence format or deployment topology.

Those concerns remain host-owned and connect through explicit requests,
information, behaviours, and trusted invocation targets.

## Shaping priorities

Bug reports and focused use cases are welcome in
[GitHub Issues](https://github.com/elchemista/spectre_directive/issues).
Proposals are most useful when they describe the host boundary involved, the
current workaround, and why the change belongs in Directive's core contract.
