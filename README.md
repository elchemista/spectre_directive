# Spectre Directive

Spectre Directive is an embeddable mission loop for Elixir agents. Give it a
mission and an optional plan; it repeatedly asks a reasoner what should happen
next, emits explicit requests for effects or missing information, and keeps
going until the mission completes, fails, or is cancelled.

It works in four forms:

- as a pure reducer with no processes or callbacks;
- as an optional supervised OTP runtime;
- inside an ordinary `GenServer`;
- alongside `Spectre.Agent` through `use Spectre.Directive`.

The package does **not** implement memory, retrieval, an LLM provider, tool
discovery, Kinetic actions, persistence, or application policy. Those remain
host concerns. Directive owns only the state and legal transitions of one live
mission.

## The contract

```text
                         ┌──────────────────────────────┐
                         │ application / Agent / UI     │
                         │ LLM, functions, policy, info │
                         └──────────────┬───────────────┘
                                        │ response
                                        ▼
mission ──► plan ──► current step ──► pure loop ──► correlated request
               ▲                         │
               └──── versioned patch ────┘
                                        │
                                        ▼
                                    outcome
```

The loop emits exactly one pending request at a time. Each request carries its
mission id, request id, plan version, step id, and context revision. A delayed
LLM or function result cannot mutate a newer request, plan, or step.

Directive owns:

- the mission, current plan, steps, and terminal outcome;
- mission-local input, assigns, and collected information;
- request correlation and deterministic state transitions;
- guided confirmation and atomic, versioned plan patches;
- an optional process per mission and supervised callback workers.

The host owns:

- model calls and provider-specific response parsing;
- executable functions and symbolic tool-name resolution;
- user questions, authorization policy, and application effects;
- durable storage, recovery, retrieval, and external information.

## Installation

```elixir
def deps do
  [
    {:spectre_directive, "~> 0.1.0"}
  ]
end
```

For local development with the sibling repositories:

```elixir
def deps do
  [
    {:spectre, path: "../spectre"},
    {:spectre_directive, path: "../spectre_directive"}
  ]
end
```

`spectre` is optional. A standalone or GenServer host does not need it.

## Quick start

Author a reusable directive with ordinary Elixir values and functions:

```elixir
defmodule MyApp.ClientLookup do
  use Spectre.Directive

  directive "client-lookup" do
    mission "Find the requested client"
    success "Return a verified client record"
    mode :fixed

    step "Read client data" do
      purpose "Resolve the client from application-owned data"

      invoke fn context ->
        client = MyApp.Clients.fetch!(context.input.client_id)
        {:complete_mission, client}
      end
    end
  end
end
```

Start it with the optional local runtime:

```elixir
{:ok, mission} =
  Spectre.Directive.start_directive(MyApp.ClientLookup,
    input: %{client_id: 42},
    execution: :auto
  )

{:ok, outcome} = Spectre.Directive.await(mission)
outcome.status
#=> :completed
```

Anonymous DSL callbacks are compiled into functions on the directive module.
For targets that must survive serialization or move between nodes, use a
behaviour module or MFA instead.

## Pure loop

The pure API never calls an LLM, executes a function, or starts a process. A
host stores the returned state and resolves each request itself.

```elixir
alias SpectreDirective.Request

{:ok, loop} =
  Spectre.Directive.new(
    mission: "Research Acme",
    success: "Return a sourced summary",
    mode: :autonomous
  )

{:request, %Request{kind: :reason} = plan_request, loop} =
  Spectre.Directive.next(loop)

{:request, %Request{kind: :reason} = step_request, loop} =
  Spectre.Directive.respond(loop, plan_request.id, {
    :propose_plan,
    [%{title: "Read the supplied client page"}]
  })

# Information can arrive between any two reasoning turns.
{:ok, loop} =
  Spectre.Directive.inform(loop, %{url: "https://example.test/acme"},
    source: :application
  )

# The previous reasoning request is now stale; next/1 emits a fresh one whose
# context includes the new information.
{:request, %Request{kind: :reason} = refreshed, loop} =
  Spectre.Directive.next(loop)

read_page = fn context ->
  url = context.last_result.url
  {:complete_mission, MyApp.Pages.read(url)}
end

{:request, %Request{kind: :invoke} = invocation, loop} =
  Spectre.Directive.respond(loop, refreshed.id, {:invoke, read_page})

result = Spectre.Directive.Invoker.call(invocation.target, invocation.context)

{:done, outcome, _loop} =
  Spectre.Directive.respond(loop, invocation.id, result)
```

Use the pure form when another runtime already owns scheduling or persistence.
The state can live in a GenServer, a Spectre flow, a database-backed process,
or a test without changing the protocol.

## Reasoner decisions

A reasoner receives `%SpectreDirective.Context{}` and returns one decision.
Tuple forms are convenient for Elixir callbacks; equivalent atom- or
string-keyed maps are accepted for decoded LLM output.

| Decision | Meaning |
| --- | --- |
| `{:propose_plan, steps}` | Propose the initial plan |
| `{:invoke, target}` | Ask the host/runtime to execute a trusted target |
| `{:ask, question}` | Wait for application or user information |
| `{:ask_policy, requirement}` | Ask the host to authorize an opaque requirement |
| `{:propose_patch, patch, info}` | Correct the current versioned plan |
| `{:complete_step, result}` | Record the step result and continue |
| `{:complete_mission, result}` | Finish successfully |
| `{:blocked, reason}` | Turn a blocker into a question boundary |

A provider-neutral description is available at runtime:

```elixir
Spectre.Directive.protocol()
Spectre.Directive.reasoning_input(context)
```

Implement a stable reasoner adapter with the public behaviour:

```elixir
defmodule MyApp.MissionReasoner do
  @behaviour Spectre.Directive.Reasoner

  @impl Spectre.Directive.Reasoner
  def decide(context, opts) do
    context
    |> Spectre.Directive.reasoning_input()
    |> MyApp.LLM.complete(opts)
  end
end
```

The return value from `MyApp.LLM.complete/2` must be one of the decision forms
above. Directive deliberately does not prescribe an SDK or model provider.

## Invocations

An invocation receives a read-only `%SpectreDirective.Context{}`. It cannot
mutate mission state directly; its return value requests the transition.

Supported targets are:

```elixir
fn context -> result end
MyApp.ReadPage
{MyApp.ReadPage, timeout: 5_000}
{MyApp.Pages, :read}
{MyApp.Pages, :read, [extra_argument]}
```

A module target implements `Spectre.Directive.Invoker`:

```elixir
defmodule MyApp.ReadPage do
  @behaviour Spectre.Directive.Invoker

  @impl Spectre.Directive.Invoker
  def invoke(context, opts) do
    page = MyApp.HTTP.get!(context.input.url, opts)
    {:inform, %{page: page}}
  end
end
```

Invocation return values are normalized as follows:

| Return | Transition |
| --- | --- |
| `{:inform, value}` or `{:ok, value}` | Add information and reason again |
| `{:complete_step, result}` | Complete the current step |
| `{:complete_mission, result}` | Complete the mission |
| `{:propose_patch, patch, info}` | Add information and propose a plan change |
| `{:ask, question}` | Emit a question request |
| `{:error, reason}` | Record the error and let the reasoner recover |

In the OTP runtime, reasoners, invocations, policies, and generic request
handlers execute in supervised, unlinked tasks. The mission process applies a
worker result only if it still matches the active request.

## Authored DSL

```elixir
defmodule MyApp.ResearchDirective do
  use Spectre.Directive

  directive "client-research" do
    mission "Research the client"
    context "Use only sources supplied by the application"
    success "Produce a sourced summary"
    mode :guided
    directive_metadata %{owner: :sales}

    step "Read client page" do
      kind :investigate
      flexibility :guided
      purpose "Collect public client information"
      reason "The summary must be grounded in a primary source"
      prompt "Extract identity, products, and visible claims"
      expects "A structured page summary"
      done_when "The relevant page facts are available"
      risk :low
      input %{section: :about}
      metadata %{source_type: :web}
      policy :external_read
      invoke {MyApp.ReadPage, url: "https://example.test"}
    end

    step "Write summary" do
      purpose "Answer the mission from collected information"
    end

    on_complete {MyApp.StoreReport, []}
  end
end
```

A module may define multiple named directives. `start_directive/2` uses the
first one unless `directive: "name"` is supplied.

The plan modes are:

| Mode | Generated plan changes |
| --- | --- |
| `:fixed` | Rejected; use an authored plan |
| `:guided` | Emitted as `:confirmation` requests |
| `:autonomous` | Applied immediately when valid |

Guided confirmations accept `:accept`, `{:accept, edited}`, `{:edit, edited}`,
or `{:reject, reason}`. Plan patches are atomic and correlated to the current
plan version. Supported operations are `:add`, `:insert_after`, `:remove`,
`:replace`, `:skip`, and `:reorder`.

## Optional OTP runtime

Start a mission with automatic callback execution:

```elixir
{:ok, mission} =
  Spectre.Directive.start_mission("Research Acme",
    reasoner: MyApp.MissionReasoner,
    reasoner_opts: [model: "my-model"],
    execution: :auto,
    policy_handler: MyApp.Policy,
    request_handler: MyApp.Questions,
    subscribers: [self()],
    request_timeout: 30_000
  )
```

Or set `execution: :manual`, subscribe, and resolve requests explicitly:

```elixir
receive do
  {:spectre_directive, mission_id, :request, request} ->
    answer = MyApp.Runtime.resolve(request)
    Spectre.Directive.respond(mission_id, request.id, answer)
end
```

Runtime events have one stable envelope:

```elixir
{:spectre_directive, mission_id, event, payload}
```

Events are `:request`, `:information`, `:assigned`, `:trace`, `:error`, and
`:outcome`. `subscribe/2` immediately sends the current request or outcome, so
a newly attached UI can resume at the live boundary.

The runtime starts lazily, or can be placed in an application supervision tree:

```elixir
children = [
  Spectre.Directive
]
```

```text
SpectreDirective.Runtime.Supervisor
├── Registry
├── DynamicSupervisor
│   └── MissionMachine (one per mission)
└── Task.Supervisor
    └── reasoner / invocation / policy workers
```

Use `pulse/1` for a compact status, `state/1` for the complete loop,
`request/1`, `plan/1`, `context/1`, `trace/1`, and `outcome/1` for focused
views. `pause/1`, `resume/1`, `cancel/2`, `stop/1`, and `await/2` manage the
mission lifecycle.

## Spectre Agent integration

`Spectre.Directive` detects an Agent at compile time. Put `use Spectre.Agent`
first so Directive can add its private reasoning route to the Agent's normal
DSL compilation:

```elixir
defmodule MyApp.ResearchAgent do
  use Spectre.Agent,
    model: MyApp.Models.default()

  use Spectre.Directive

  directive "client-research" do
    mission "Research the client"
    success "Return a sourced summary"
    mode :guided
  end

  @impl Spectre.Directive.Handler
  def handle_directive({:invocation, "read_page"}, _context) do
    {:ok, &MyApp.Pages.read_from_directive/1}
  end

  def handle_directive(message, context), do: super(message, context)
end
```

Start through the generated Agent API:

```elixir
{:ok, mission} =
  MyApp.ResearchAgent.start_directive("client-research",
    input: %{url: "https://example.test/acme"},
    subscribers: [self()]
  )
```

By default, reasoning uses the model configuration already carried by the
Spectre turn. Override `handle_directive({:reason, context}, spectre_context)`
to use a custom reasoner.

An LLM may name an invocation, but it may not invent executable BEAM code.
Every generated string target is passed to
`handle_directive({:invocation, target}, context)` and must be resolved by the
host to a trusted function, module, or MFA. Unresolved targets fail closed.

The adapter references Spectre dynamically, so this package still compiles and
runs when Spectre is absent. JSON model responses require `Jason` to be
available in the host application.

## GenServer integration

Put `use GenServer` before `use Spectre.Directive`. Directive generates
`start_directive/3`, routes its runtime messages through `handle_directive/2`,
and leaves the mission state isolated in its own supervised process.

```elixir
defmodule MyApp.MissionHost do
  use GenServer
  use Spectre.Directive

  directive "research" do
    mission "Research the client"
    mode :guided
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl Spectre.Directive.Handler
  def handle_directive({:request, mission_id, request}, state) do
    response = MyApp.Runtime.resolve(request)
    Spectre.Directive.respond(mission_id, request.id, response)
    {:noreply, state}
  end

  def handle_directive({:outcome, mission_id, outcome}, state) do
    {:noreply, Map.put(state, mission_id, outcome)}
  end

  def handle_directive(message, state), do: super(message, state)
end
```

```elixir
{:ok, server} = GenServer.start_link(MyApp.MissionHost, %{})

{:ok, mission} =
  MyApp.MissionHost.start_directive(server, "research",
    execution: :manual
  )
```

If the module owns a custom `handle_info/2`, call the generated
`directive_handle_info/2` from its Directive clause. Pass
`gen_server_handler: false` to `use Spectre.Directive` when installing all
message routing manually.

Both Agent and GenServer hosts use the same callback name:

```elixir
handle_directive({:reason, context}, host_context)
handle_directive({:invocation, target}, context)
handle_directive({event, mission_id, payload}, gen_server_state)
```

## Adding information while a mission runs

`inform/3` appends mission-local information; `assign/2` merges
application-owned values. Both increment the context revision and make the new
values visible to every later reasoner and invocation.

If either call arrives during a `:reason` request, Directive invalidates that
request and emits a replacement using the newer context. A response to the old
request returns a stale-response error. Active invocation and policy requests
are not cancelled because they may already represent application effects.

Information is a chronological list for the current mission only. Directive
does not retrieve, rank, persist, or reuse it across missions. Applications
that need those features can inject their own retrieved data through
`inform/3` or the initial `information:` option.

## Design boundaries

- No provider SDK is required. Reasoners are functions or behaviour modules.
- No tool language is required. Invocations are functions, modules, or MFAs.
- No persistence format is imposed. Use the pure state when persistence is a
  host responsibility.
- No memory layer exists. Mission-local information disappears with the live
  state unless the host stores it.
- No Kinetic integration exists. A Kinetic interpreter can still be called by
  an application invocation like any other function.
- No arbitrary LLM target is executed. Symbolic Agent targets cross an
  explicit host trust boundary.

## Development

```bash
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix credo suggest "lib/**/*.ex" --strict
mix dialyzer
mix docs
```

The implementation roadmap and architectural decisions are in
[`PLAN.md`](PLAN.md).
