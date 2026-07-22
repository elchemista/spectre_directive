# SpectreDirective implementation plan

## Purpose

SpectreDirective is an embeddable mission loop. It owns the deterministic
relationship between a mission, its living plan, the current step, information
collected during the run, pending external requests, and the final outcome.

It does not own memory, retrieval, tool discovery, tool-selection syntax, model
SDKs, policies, persistence, or application side effects. Those concerns are
provided by the host application, a Spectre agent, or an ordinary Elixir
process through requests, responses, functions, and behaviours.

## Core loop

```text
mission
  -> create or accept plan
  -> confirm generated plan when guided
  -> select current step
  -> reason about the step
       -> invoke a function
       -> ask a question
       -> request policy
       -> propose a plan patch
       -> complete the step
       -> complete the mission
  -> add returned information
  -> reason again
  -> next step or revised plan
  -> mission outcome
```

The mission loop and each step loop are resumable. Only one correlated request
is pending at a time in the first implementation.

## Ownership

SpectreDirective owns:

- mission, plan, step, and loop state;
- mission-local working information;
- request correlation and legal transitions;
- generated-plan and plan-patch confirmation;
- step and mission completion;
- an optional supervised OTP runtime.

The host owns:

- LLM calls and response interpretation;
- functions, tools, effects, and policies;
- user interaction;
- persistence and recovery;
- any external source of information.

## Public execution protocol

The pure engine accepts events and returns either a pending request or a final
outcome. Requests have stable ids, mission ids, plan versions, and step ids.

Request kinds:

- `:reason` asks the configured reasoner for an `AgentDecision`;
- `:invoke` asks the host to run an anonymous function or behaviour module;
- `:question` waits for application or user information;
- `:policy` waits for an opaque host policy decision;
- `:confirmation` waits for acceptance, editing, or rejection of generated
  plans and patches.

Invocation results normalize to:

- `{:inform, information}`;
- `{:complete_step, result}`;
- `{:complete_mission, result}`;
- `{:propose_patch, patch, information}`;
- `{:ask, question}`;
- `{:error, reason}`.

`{:ok, value}` is shorthand for `{:inform, value}`.

## Invocation targets

Local invocations support:

```elixir
fn context -> result end
MyApp.Invoker
{MyApp.Invoker, options}
```

Behaviour modules implement `SpectreDirective.Invoker`. Anonymous functions
are convenient for live local missions and tests. Behaviour modules are the
stable choice when plans must be recreated after restart or moved between
nodes.

The core never executes user code inside the mission process. The optional OTP
runtime uses supervised, unlinked tasks and correlates their results before the
mission process applies a transition.

## OTP runtime

```text
SpectreDirective.Runtime.Supervisor
├── Registry
├── DynamicSupervisor
│   └── one MissionMachine per mission
└── Task.Supervisor
    └── reasoner and invocation tasks
```

The pure engine remains usable without this supervision tree. A host may store
the returned state in its own GenServer, Spectre state, database, or another
runtime.

## DSL direction

The authored DSL describes only mission-loop concerns:

```elixir
directive "client-research" do
  mission "Research the client"
  context "Use only information supplied during this run"
  success "A verified client summary is produced"
  mode :guided

  step "Read client page" do
    purpose "Collect public client information"
    invoke {MyApp.ReadClientPage, url: "https://example.com"}
  end

  step "Produce summary" do
    purpose "Answer the mission with the collected information"
  end

  on_complete {MyApp.SaveClientReport, []}
end
```

Generated steps cannot invent executable BEAM code. A host reasoner translates
an LLM tool decision into a trusted invocation function or behaviour target.

## Module architecture

```text
Spectre.Directive                 public facade and `use` entry point
├── SpectreDirective.DSL          reusable mission/step blueprints
├── SpectreDirective.Loop         pure state and reducers
│   ├── Engine                    request/response state machine
│   ├── PlanReducer               plan confirmation and correction
│   └── Completion                terminal transitions
├── SpectreDirective.Runtime      optional OTP execution adapter
│   ├── MissionMachine            one correlated mission process
│   ├── RequestExecutor           supervised callback dispatch
│   └── Notifier                  application event envelope
└── SpectreDirective.Integration  compile-time host adapters
    ├── SpectreAgent              optional Agent reasoning route
    └── GenServer                 native message dispatch
```

Dependencies point inward: integrations translate host values into the public
protocol; the pure loop does not reference Spectre, GenServer callbacks, JSON,
or provider SDKs.

## Removed legacy scope

The refactor removed from SpectreDirective:

- memory stores, recall, scopes, and remember rules;
- capability discovery and sibling-library adapters;
- Kinetic, Lens, and Mnemonic dependencies and generators;
- alignment, impact, and correction-provider layers;
- the old host-owned `pulse -> next_step -> complete_step` execution loop.

External systems remain usable because their results enter through
`inform/3`, request responses, or invocation functions.

## Implementation status

- [x] Mission-local information, loop context, decisions, requests, outcomes,
  invocation contracts, and plan patches.
- [x] Pure request/response engine with plan, step, and context correlation.
- [x] Supervised local reasoner, invocation, policy, and request execution.
- [x] Public `Spectre.Directive` facade and authored DSL.
- [x] Optional Spectre Agent integration without a compile-time dependency.
- [x] Native GenServer integration through the same `handle_directive/2`
  callback name.
- [x] Removal of memory, sibling-tool, capability, alignment, and correction
  layers.
- [x] ExDoc API documentation, standalone/Agent/GenServer guides, Credo, and
  Dialyzer validation.

## Extension roadmap

Future integrations should stay outside the pure engine and preserve the same
request/response protocol:

1. Telemetry events for request latency, plan revisions, and mission outcomes.
2. Optional snapshot codecs that validate serializable loop state without
   choosing a database or persistence lifecycle.
3. Provider-specific reasoner packages built on `Spectre.Directive.Reasoner`.
4. UI helpers for guided confirmations and questions, implemented as event
   subscribers rather than new loop state.
5. Distributed runtime adapters that store pure state behind an application
   registry while retaining request correlation.
