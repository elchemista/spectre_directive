# SpectreDirective

SpectreDirective is a self-correcting mission planner for Spectre agents.

It is __NOT__ a workflow engine, task queue, command runner, browser automation
library, or YAML-shaped workflow wrapper. It gives an agent a mission, keeps a living
plan, checks whether each step still matters, and corrects direction when new
information changes the situation.

The short version:

```text
Mission
  -> Knowledge
  -> Capabilities
  -> Plan
  -> Step
  -> Observation
  -> Impact
  -> Alignment
  -> Correction
  -> Trace / Pulse
  -> Control
```

The plan is not sacred. The plan is alive.

## Why

Agents are very good at producing motion. Sometimes that motion is useful.
Sometimes it is a scenic tour through irrelevance.

SpectreDirective exists to keep asking:

```text
Given what we know now, should we still do this?
```

That is the difference between a mission planner and a step runner. A step
runner executes the next item. A mission planner checks whether the next item
still serves the mission.

## Installation

For local Spectre development:

```elixir
def deps do
  [
    {:spectre_directive, github: "elchemista/spectre_directive"}
  ]
end
```

When published:

```elixir
def deps do
  [
    {:spectre_directive, "~> 0.1.0"}
  ]
end
```

## Quick Start

For an agent-created mission, use `SpectreDirective.create/1`:

```elixir
{:ok, mission} =
  SpectreDirective.create(%{
    mission: "Make sure a new user can finish sign up",
    context: "This is a release check. Do not use real customer data.",
    success: "A test user reaches a valid post-signup state.",
    capabilities: [
      %{name: :observe_page, description: "Observe the current browser page."},
      %{name: :fill_form, description: "Fill fields in a test form.", risk: :medium}
    ],
    mode: :guided,
    model: &MyApp.ModelClient.complete/1
  })
```

`model` receives SpectreDirective's English planning prompts and returns normal
text. No planner module is needed. With `mode: :guided`, the mission starts in
manual guided planning. Your process asks for, accepts, edits, or rejects each
planning item before execution begins.

For reusable authored checks, use `use SpectreDirective`:

```elixir
defmodule MyApp.Directives.Signup do
  use SpectreDirective

  directive "signup-check" do
    mission "Make sure a new user can finish sign up"
    context "This is a release check. Do not use real customer data."
    success "A test user reaches dashboard, onboarding, or a clear verification screen."
    mode :guided

    capabilities do
      require_capability :observe_current_state
      allow :form_fill
      allow :screenshot
      deny :real_payment
    end

    strategies do
      strategy :qa_flow
      strategy :safe_operator
    end

    step "Observe signup entry" do
      kind :observe
      flexibility :guided
      purpose "Understand the real signup options before acting"
      expects "Visible signup methods, required fields, and possible blockers."
    end

    step "Verify mission result" do
      kind :verify
      flexibility :locked
      purpose "Decide if the mission succeeded"
      expects "Pass/fail result with evidence and blocker."
    end
  end
end
```

Run it:

```elixir
{:ok, mission} = SpectreDirective.start_directive(MyApp.Directives.Signup)

{:ok, pulse} = SpectreDirective.pulse(mission)
{:ok, step} = SpectreDirective.next_step(mission)

{:ok, pulse} =
  SpectreDirective.complete_step(mission, %{
    summary: "Signup form is visible and asks for email and password.",
    facts: ["The public signup form loads."],
    mission_relevant_facts: ["Primary signup path is available."],
    impact: "The mission can continue through the normal signup path."
  })
```

SpectreDirective lazily starts its runtime infrastructure. If your application
wants supervision ownership, add it to your own tree:

```elixir
children = [
  SpectreDirective
]
```

## Connecting An AI Model

SpectreDirective does not call OpenAI, Anthropic, Ollama, or any other model
provider directly. That is intentional. The library is the mission planner and
state machine. Your application owns the model calls.

There are two model moments:

- Planning: the model can create the initial plan and steps.
- Execution: the model can complete each selected step and report observations.

For AI-created plans, the small path is `create/1`:

```elixir
{:ok, mission} =
  SpectreDirective.create(%{
    mission: "Check the signup flow",
    context: "Release QA",
    capabilities: [:observe_page, :fill_form],
    mode: :guided,
    model: &MyApp.ModelClient.complete/1
  })
```

The function receives an English prompt and returns English planning text.
No planner module is required for that.

Use draft planning when one full plan is enough:

```elixir
{:ok, mission} =
  SpectreDirective.create(%{
    mission: "Check the signup flow",
    model: &MyApp.ModelClient.complete/1,
    planning_mode: :draft
  })
```

Use guided planning when the model should think one piece at a time:

```elixir
{:ok, mission} =
  SpectreDirective.create(%{
    mission: "Check the signup flow",
    model: &MyApp.ModelClient.complete/1,
    planning_mode: :guided,
    planning_subscribers: [self()]
  })
```

Guided planning is manual by design. Drive it from a LiveView, GenServer, CLI,
or another model process:

```elixir
{:ok, proposal} = SpectreDirective.propose_plan_item(mission)
{:ok, planning} = SpectreDirective.accept_plan_item(mission)

{:ok, proposal} = SpectreDirective.propose_plan_item(mission)
{:ok, planning} =
  SpectreDirective.accept_plan_item(mission, %{
    type: :step,
    step: %{title: "Observe signup", kind: :observe, purpose: "Inspect the visible flow."}
  })

{:ok, pulse} = SpectreDirective.finish_planning(mission)
```

Any process can also submit a proposal directly:

```elixir
SpectreDirective.submit_plan_item(mission, %{
  type: :strategy,
  strategy: "Observe first, then verify with evidence."
})
```

For larger applications, you can still implement `SpectreDirective.Planner`:

```elixir
defmodule MyApp.DirectivePlanner do
  @behaviour SpectreDirective.Planner

  @impl SpectreDirective.Planner
  def draft_plan(request, _opts) do
    MyApp.ModelClient.complete(request.prompt)
  end
end
```

In both modes, the model is asked for normal planning text, not a data blob:

```text
Strategy: inspect the real signup path before acting.

Plan:
1. Observe signup entry
   kind: observe
   purpose: Understand the available signup options.
   expects: Visible methods, required fields, and blockers.
   capability: observe_page
   flexibility: guided

2. Verify signup result
   kind: verify
   purpose: Decide whether the signup path satisfies the release check.
   expects: Pass/fail result with evidence.
   flexibility: locked
```

Planning runs after memory recall and capability discovery, so the model can
plan with what the mission already knows and what the agent can actually do.
SpectreDirective parses the textual draft into real steps. If the draft cannot
be parsed, it falls back to the existing authored or emergent plan and records
that in the trace.

Execution is the second loop. The host app owns model and tool execution;
SpectreDirective owns mission state, planning state, alignment requests,
corrections, control, pulse, and trace:

```text
pulse -> next_step -> knowledge/capabilities
  -> host model/tools/assertions
  -> complete_step
  -> repeat
```

In code, that can look like this:

```elixir
defmodule MyApp.DirectiveAgent do
  @terminal [:finished, :stopped, :aborted]

  def run(directive_module, opts \\ []) do
    {:ok, mission} = SpectreDirective.start_directive(directive_module, opts)
    loop(mission, opts)
  end

  defp loop(mission, opts) do
    {:ok, pulse} = SpectreDirective.pulse(mission)

    if pulse.status in @terminal do
      {:ok, pulse}
    else
      {:ok, step} = SpectreDirective.next_step(mission)
      {:ok, knowledge} = SpectreDirective.knowledge(mission)
      {:ok, capabilities} = SpectreDirective.capabilities(mission)

      observation =
        MyApp.AIModel.complete_step(%{
          mission: mission,
          pulse: pulse,
          step: step,
          knowledge: knowledge,
          capabilities: capabilities,
          tools: Keyword.get(opts, :tools, [])
        })

      {:ok, _pulse} = SpectreDirective.complete_step(mission, observation)
      loop(mission, opts)
    end
  end
end
```

The model adapter is normal host-application code:

```elixir
defmodule MyApp.AIModel do
  def complete_step(%{
        step: step,
        pulse: pulse,
        knowledge: knowledge,
        capabilities: capabilities,
        tools: tools
      }) do
    response =
      MyApp.ModelClient.respond(%{
        system: "You are executing one SpectreDirective mission step.",
        mission: pulse.mission,
        current_step: step,
        known_facts: knowledge.known_facts,
        capabilities: capabilities.capabilities,
        tools: tools
      })

    %{
      summary: response.summary,
      facts: response.facts,
      mission_relevant_facts: response.mission_relevant_facts,
      evidence: response.evidence,
      impact: response.impact,
      correction: response.correction || :continue,
      confidence: response.confidence,
      raw: response
    }
  end
end
```

Capability adapters tell SpectreDirective what the agent is allowed to do.
The model runner decides when to use those capabilities and returns what
happened. That separation keeps this library independent from every model SDK
while still making it easy to plug into any agent stack.

## Emergent Missions

You do not need an authored directive when the route is unknown:

```elixir
{:ok, mission} =
  SpectreDirective.start_mission("Analyze a GitHub profile for React frontend fit",
    context: "Backend evidence is secondary; React/frontend evidence is primary.",
    success: "Concise fit summary with evidence and uncertainty.",
    mode: :adaptive
  )
```

This creates a conservative skeleton plan:

```text
remember -> observe -> investigate -> verify -> summarize
```

It is a first guess, not a prophecy. First guesses are allowed to be wrong. That
is why the correction loop exists.

## DSL Validation

Authored directives fail at compile time when the basics are missing:

```text
mission is required
context is required
success is required
at least one step is required
each step needs a purpose
kind, flexibility, and risk must be known values
```

No silent empty mission. No mystery plan with zero steps. Runtime has enough
uncertainty already.

## Runtime Loop

The mission loop is host-owned:

```text
pulse
next_step
knowledge + capabilities
host model/tool/assertion execution
complete_step
repeat
```

Inside SpectreDirective, each turn updates the living mission:

```text
recall memory -> discover capabilities -> load/create plan
pre-step alignment -> selected step
observation -> impact -> knowledge -> correction
post-step alignment -> trace/pulse/control state
```

Two checks matter most:

- Before a step: is this still worth doing?
- After a step: what changed because of what we learned?

That tiny hesitation before blindly doing the next thing is the library.

Status handling is deliberately plain OTP state:

- `:planning` means manual guided planning is still open. Use
  `propose_plan_item/2`, `submit_plan_item/2`, `accept_plan_item/2`,
  `reject_plan_item/2`, and `finish_planning/2`.
- `:waiting` means alignment paused on risk or approval. Use `control/2` with
  `:approve`, `:reject`, `:stop`, or `{:revise_plan, correction}`.
- `:blocked` means alignment needs more context, an answer, or plan revision.
  A human, GenServer, LiveView, CLI, or another AI process can call
  `control(ref, {:revise_plan, correction})`.
- `:paused` is explicit host control. Use `control(ref, :resume)` to continue.
- `:finished`, `:stopped`, and `:aborted` are terminal.

## Public API

```elixir
SpectreDirective.create(attrs)
SpectreDirective.start_mission(mission, opts \\ [])
SpectreDirective.start_directive(module_or_blueprint, opts \\ [])
SpectreDirective.pulse(ref)
SpectreDirective.trace(ref)
SpectreDirective.plan(ref)
SpectreDirective.knowledge(ref)
SpectreDirective.capabilities(ref)
SpectreDirective.planning_state(ref)
SpectreDirective.propose_plan_item(ref, opts \\ [])
SpectreDirective.submit_plan_item(ref, proposal)
SpectreDirective.accept_plan_item(ref, item_or_edit \\ :pending)
SpectreDirective.reject_plan_item(ref, reason)
SpectreDirective.finish_planning(ref, reason \\ nil)
SpectreDirective.next_step(ref)
SpectreDirective.complete_step(ref, observation)
SpectreDirective.apply_observation(ref, observation)
SpectreDirective.control(ref, action)
SpectreDirective.await(ref, timeout \\ 60_000)
```

`ref` can be a mission process pid or mission id.

## Pulse And Trace

`pulse/1` is the live meaning snapshot:

```elixir
%SpectreDirective.Pulse{
  mission: "Analyze a GitHub profile for React frontend fit",
  status: :running,
  current_step: %SpectreDirective.Step{title: "Search frontend evidence"},
  current_understanding: "Backend evidence is strong; React evidence is not yet found.",
  alignment: %SpectreDirective.Alignment.Result{status: :aligned},
  risk: :low,
  blocked?: false,
  next_expected_action: "continue: Search frontend evidence",
  controls: [:pause, :stop, :retry, :skip, :revise_plan, :finish_early]
}
```

`trace/1` is the readable mission story. Logs say what happened. Trace explains
why it mattered.

## Core Concepts

- `Mission` is the goal, context, success criteria, status, risk boundaries, and
  memory scope.
- `Knowledge` is layered: known facts, assumptions, observations, derived facts,
  mission-relevant facts, low-relevance facts, decisions, confidence, and open
  questions.
- `Capability` is something the mission can realistically do now, not just a
  function name in a tool list.
- `Plan` is the current strategy. It is versioned because correction is normal.
- `Step` is intent plus action shape: kind, purpose, reason, expected output,
  done condition, risk, required capability, status, and flexibility.
- `Observation` says what happened.
- `Impact` says why it matters.
- `Correction` says what should change.
- `Pulse` says what is happening now.
- `Trace` says why the mission moved.

The useful distinction is this: true and useful are not the same word. A fact
can be accurate and still be low-value for the current mission.

Mission states:

```text
planning
running
paused
waiting
blocked
finished
stopped
aborted
```

The runtime is a state machine because missions actually have states, not
because state machines look important in diagrams.

## Corrections

Correction types:

```text
continue
skip_step
remove_steps
add_step
replace_step
reorder_steps
narrow_scope
expand_scope
ask_user
wait
retry
delegate
finish_early
abort
```

Correction strategies:

```text
tactical
strategic
scope
evidence
cost
risk
confidence
drift
```

Example:

```elixir
SpectreDirective.complete_step(mission, %{
  summary: "The active repositories are mostly backend Elixir libraries.",
  mission_relevant_facts: ["React/frontend evidence is weak."],
  impact: "This lowers confidence in React frontend fit.",
  correction: %{
    type: :finish_early,
    strategy: :confidence,
    reason: "Enough evidence exists to answer the mission."
  }
})
```

Do not inspect twenty more backend repositories just because the plan was
written before the evidence arrived. That is how agents become very busy and not
very helpful.

## Integrations

SpectreDirective has five integration boundaries. The host app composes them:
planner/model for plan text, alignment for model-backed judgment, capability
adapters for available tools, memory adapters for recall/remember, and the host
executor for actual model/tool/assertion execution. SpectreDirective does not
run your tools; it keeps the mission state coherent while your app drives them.

Alignment modules implement `SpectreDirective.Alignment`:

```elixir
defmodule MyApp.SpectreDirective.Alignment do
  @behaviour SpectreDirective.Alignment

  alias SpectreDirective.Alignment.Result

  @impl SpectreDirective.Alignment
  def check_alignment(request, _opts) do
    # Send request.prompt, or the structured request fields, to your model.
    # Then map the model judgment into an Alignment.Result.
    MyApp.Model.align(request.prompt)
    |> case do
      {:ok, %{safe?: true, reason: reason}} ->
        Result.new(
          status: :aligned,
          recommendation: :continue,
          check: :mission_relevance,
          reason: reason
        )

      {:ok, %{action: :pause, reason: reason}} ->
        Result.new(
          status: :risky,
          recommendation: :pause,
          check: :risk,
          reason: reason
        )
    end
  end
end

SpectreDirective.start_mission("Check signup",
  alignment: MyApp.SpectreDirective.Alignment
)
```

You can also configure a default:

```elixir
config :spectre_directive,
  alignment: MyApp.SpectreDirective.Alignment
```

Memory adapters implement `SpectreDirective.MemoryStore`:

```elixir
defmodule MyApp.SpectreDirective.MnemonicAdapter do
  @behaviour SpectreDirective.MemoryStore

  alias SpectreDirective.Mission

  @impl SpectreDirective.MemoryStore
  def recall(%Mission{} = mission, opts) do
    SpectreMnemonic.recall(mission.goal, Keyword.put_new(opts, :scope, mission.memory_scope))
  end

  @impl SpectreDirective.MemoryStore
  def remember(record, opts) do
    SpectreMnemonic.remember(record, opts)
  end
end
```

Capability adapters implement `SpectreDirective.CapabilityProvider`:

```elixir
defmodule MyApp.SpectreDirective.LensAdapter do
  @behaviour SpectreDirective.CapabilityProvider

  alias SpectreDirective.Capability
  alias SpectreDirective.MissionBlueprint

  @impl SpectreDirective.CapabilityProvider
  def discover(%MissionBlueprint{}, _opts) do
    [
      Capability.new(
        name: :observe_page,
        description: "Observe a browser page through SpectreLens.",
        source: :spectre_lens,
        risk: :low
      )
    ]
  end
end
```

Use adapters at mission start:

```elixir
{:ok, mission} =
  SpectreDirective.start_mission("Check signup",
    memory_adapter: MyApp.SpectreDirective.MnemonicAdapter,
    capability_adapters: [
      MyApp.SpectreDirective.KineticAdapter,
      MyApp.SpectreDirective.LensAdapter
    ],
    kinetic: kinetic_runtime
  )
```

When a human supervisor or AI reviewer needs to repair a blocked plan, use a
normal correction through control:

```elixir
SpectreDirective.control(mission, {
  :revise_plan,
  %{
    type: :remove_steps,
    strategy: :strategic,
    reason: "The reviewer removed a stale blocked step.",
    changes: %{matching: "obsolete verification"}
  }
})
```

Generate starter adapters in a host app:

```bash
mix spectre_directive.gen.integration
mix spectre_directive.gen.integration --only mnemonic,lens
```

The generated modules live in your app namespace. SpectreDirective does not ship
compiled dependencies on SpectreMnemonic, SpectreLens, or SpectreKinetic. That
boundary is deliberate: imagination on one side, consequences on the other.
