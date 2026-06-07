defmodule SpectreDirectiveRuntimeTest do
  use ExUnit.Case

  alias SpectreDirective.Correction
  alias SpectreDirective.Observation
  alias SpectreDirective.Step

  defmodule FakeMemory do
    def recall(mission, opts) do
      send(opts[:parent], {:recalled, mission.goal})
      {:ok, %{moments: [%{text: "Last run failed at email verification."}]}}
    end

    def remember(record, opts) do
      send(opts[:parent], {:remembered, record.observation.summary})
      :ok
    end
  end

  defmodule FakeKinetic do
    def discover(_directive, opts) do
      send(opts[:parent], :kinetic_discovered)
      [%{name: :inspect_github_repository, source: __MODULE__, risk: :low}]
    end
  end

  defmodule FakeLens do
    def discover(_directive, opts) do
      send(opts[:parent], :lens_discovered)
      [%{name: :observe_page, source: __MODULE__, risk: :low}]
    end
  end

  defmodule FakeAIPlanner do
    @behaviour SpectreDirective.Planner

    @impl SpectreDirective.Planner
    def draft_plan(request, opts) do
      capability_names = Enum.map(request.capabilities.capabilities, & &1.name)

      send(
        opts[:parent],
        {:ai_planned, request.mission.goal, request.knowledge.known_facts, capability_names,
         request.prompt}
      )

      """
      Strategy: inspect the real signup surface before deciding.

      Plan:
      1. AI-created observation step
         kind: observe
         purpose: Inspect the current signup surface.
         capability: observe_page
         flexibility: agentic

      2. AI-created verification step
         kind: verify
         purpose: Check whether the observed path satisfies the mission.
         flexibility: locked
      """
    end
  end

  defmodule RaisingAIPlanner do
    @behaviour SpectreDirective.Planner

    @impl SpectreDirective.Planner
    def draft_plan(_request, _opts), do: raise("model unavailable")
  end

  defmodule ResearchDirective do
    use SpectreDirective

    directive "github-react-fit" do
      mission("Analyze Yuriy's GitHub")

      context("""
      We need to know if Yuriy is a good fit for a React frontend team.
      Backend skill is useful only as secondary evidence.
      """)

      success("A concise fit summary focused on React/frontend evidence.")
      mode(:adaptive)

      capabilities do
        allow(:inspect_github_repository)
      end

      step "Deep inspect backend repository" do
        kind(:investigate)
        flexibility(:optional)
        purpose("Deep backend-only repository review")
      end

      step "Search frontend evidence" do
        kind(:investigate)
        flexibility(:agentic)
        capability(:inspect_github_repository)
        purpose("Find React, TypeScript, JavaScript, frontend and UI evidence")
      end
    end
  end

  test "runtime supervisor is optional for host applications" do
    assert %{start: {SpectreDirective.Runtime.Supervisor, :start_link, [_opts]}} =
             SpectreDirective.child_spec([])
  end

  test "mission starts with memory recall, capability discovery, pulse, and trace" do
    assert {:ok, pid} =
             SpectreDirective.start_directive(ResearchDirective,
               memory_adapter: FakeMemory,
               memory_opts: [parent: self()],
               capability_adapters: [FakeKinetic, FakeLens],
               parent: self()
             )

    assert_receive {:recalled, "Analyze Yuriy's GitHub"}
    assert_receive :kinetic_discovered
    assert_receive :lens_discovered

    assert {:ok, pulse} = SpectreDirective.pulse(pid)
    assert pulse.mission == "Analyze Yuriy's GitHub"
    assert pulse.status == :running
    assert pulse.current_step.title == "Search frontend evidence"
    assert pulse.alignment.status == :aligned
    assert pulse.current_understanding =~ "Last run failed at email verification."

    assert {:ok, trace} = SpectreDirective.trace(pid)
    assert Enum.any?(trace, &(&1.type == :started))
    assert Enum.any?(trace, &(&1.type == :correction and &1.message =~ "Skipped misaligned step"))
  end

  test "completing a step records observation, impact, correction, knowledge, and memory" do
    assert {:ok, pid} =
             SpectreDirective.start_directive(ResearchDirective,
               memory_adapter: FakeMemory,
               memory_opts: [parent: self()],
               capability_adapters: [FakeKinetic],
               parent: self()
             )

    assert_receive {:recalled, _}
    assert_receive :kinetic_discovered

    observation = %{
      summary: "Found little React evidence in active repositories.",
      facts: ["Most active repositories are Elixir libraries."],
      mission_relevant_facts: ["React/frontend evidence is weak."],
      decisions: ["finish early because enough evidence exists"],
      impact: "This weakens React frontend fit confidence.",
      correction: %{
        type: :finish_early,
        strategy: :confidence,
        reason: "Enough evidence exists to answer the hiring-fit mission."
      }
    }

    assert {:ok, pulse} = SpectreDirective.complete_step(pid, observation)
    assert pulse.status == :finished
    assert pulse.current_understanding =~ "React/frontend evidence is weak."

    assert_receive {:remembered, "Found little React evidence in active repositories."}

    assert {:ok, knowledge} = SpectreDirective.knowledge(pid)
    assert "Most active repositories are Elixir libraries." in knowledge.known_facts
    assert Enum.any?(knowledge.observations, &match?(%Observation{}, &1))

    assert {:ok, plan} = SpectreDirective.plan(pid)
    assert plan.version == 2
    assert [%{correction: %Correction{type: :finish_early}}] = plan.revision_history
  end

  test "start_mission creates an emergent directive with a deterministic skeleton" do
    assert {:ok, pid} =
             SpectreDirective.start_mission("Check the signup flow",
               context: "Release QA",
               memory_adapter: FakeMemory,
               memory_opts: [parent: self()],
               capability_adapters: []
             )

    assert_receive {:recalled, "Check the signup flow"}
    assert {:ok, %Step{kind: :remember}} = SpectreDirective.next_step(pid)
    assert {:ok, plan} = SpectreDirective.plan(pid)
    assert length(plan.steps) == 5
    assert plan.source == :agent_generated
  end

  test "planner adapter can create the initial plan with recalled knowledge and capabilities" do
    assert {:ok, pid} =
             SpectreDirective.start_mission("Let the model plan signup QA",
               context: "Release QA",
               memory_adapter: FakeMemory,
               memory_opts: [parent: self()],
               capability_adapters: [FakeLens],
               planner: FakeAIPlanner,
               parent: self()
             )

    assert_receive {:recalled, "Let the model plan signup QA"}
    assert_receive :lens_discovered

    assert_receive {:ai_planned, "Let the model plan signup QA", known_facts, capability_names,
                    prompt}

    assert "Last run failed at email verification." in known_facts
    assert :observe_page in capability_names
    assert prompt =~ "Do not answer with JSON"

    assert {:ok, step} = SpectreDirective.next_step(pid)
    assert step.title == "AI-created observation step"

    assert {:ok, plan} = SpectreDirective.plan(pid)

    assert Enum.map(plan.steps, & &1.title) == [
             "AI-created observation step",
             "AI-created verification step"
           ]

    assert plan.source == :agent_generated

    assert {:ok, trace} = SpectreDirective.trace(pid)
    assert Enum.any?(trace, &(&1.type == :planned))
  end

  test "planning_model function can create a draft plan without a planner module" do
    parent = self()

    model = fn prompt ->
      send(parent, {:draft_prompt, prompt})

      """
      Plan:
      1. Function model observation step
         kind: observe
         purpose: Observe through a simple prompt function.
      """
    end

    assert {:ok, pid} =
             SpectreDirective.start_mission("Plan with a function",
               planning_model: model
             )

    assert_receive {:draft_prompt, prompt}
    assert prompt =~ "Write a useful mission plan in normal text"

    assert {:ok, step} = SpectreDirective.next_step(pid)
    assert step.title == "Function model observation step"
  end

  test "guided planning asks for strategy, then one step at a time until finish" do
    parent = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    model = fn prompt ->
      turn = Agent.get_and_update(counter, &{&1, &1 + 1})
      send(parent, {:guided_prompt, turn, prompt})

      case turn do
        0 ->
          "Strategy: observe first, then verify only if enough evidence exists."

        1 ->
          """
          Step: Guided observation
          kind: observe
          purpose: Inspect the visible signup entry before acting.
          capability: observe_page
          """

        2 ->
          """
          Step: Guided verification
          kind: verify
          purpose: Decide whether the observed state satisfies the mission.
          """

        _turn ->
          "Finish: the plan has enough steps."
      end
    end

    assert {:ok, pid} =
             SpectreDirective.start_mission("Plan step by step",
               planning_model: model,
               planning_mode: :guided,
               planning_max_steps: 5
             )

    assert_receive {:guided_prompt, 0, strategy_prompt}
    assert strategy_prompt =~ "Do not write steps yet"

    assert_receive {:guided_prompt, 1, first_step_prompt}
    assert first_step_prompt =~ "Generate only step 1"
    assert first_step_prompt =~ "Steps already generated:\n-"

    assert_receive {:guided_prompt, 2, second_step_prompt}
    assert second_step_prompt =~ "Generate only step 2"
    assert second_step_prompt =~ "Guided observation"

    assert_receive {:guided_prompt, 3, finish_prompt}
    assert finish_prompt =~ "Generate only step 3"
    assert finish_prompt =~ "Guided verification"

    assert {:ok, plan} = SpectreDirective.plan(pid)
    assert Enum.map(plan.steps, & &1.title) == ["Guided observation", "Guided verification"]

    assert {:ok, trace} = SpectreDirective.trace(pid)
    assert Enum.any?(trace, &(&1.type == :planned and &1.data.mode == :guided))
  end

  test "create starts a guided mission from one simple agent map" do
    parent = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    model = fn prompt ->
      turn = Agent.get_and_update(counter, &{&1, &1 + 1})
      send(parent, {:create_prompt, turn, prompt})

      case turn do
        0 ->
          "Strategy: observe the signup page, then stop with a small useful plan."

        1 ->
          """
          Step: Observe signup page
          kind: observe
          purpose: Understand the available signup options.
          capability: observe_page
          """

        _turn ->
          "Finish: one observation step is enough to begin."
      end
    end

    assert {:ok, pid} =
             SpectreDirective.create(%{
               mission: "Make sure a new user can finish sign up",
               context: "Release check. Do not use real customer data.",
               success: "A test user reaches a valid post-signup state.",
               capabilities: [
                 %{name: :observe_page, description: "Observe the current browser page."}
               ],
               mode: :guided,
               model: model
             })

    assert_receive {:create_prompt, 0, strategy_prompt}
    assert strategy_prompt =~ "Make sure a new user can finish sign up"
    assert strategy_prompt =~ "observe_page"

    assert_receive {:create_prompt, 1, step_prompt}
    assert step_prompt =~ "Generate only step 1"

    assert_receive {:create_prompt, 2, finish_prompt}
    assert finish_prompt =~ "Observe signup page"

    assert {:ok, step} = SpectreDirective.next_step(pid)
    assert step.title == "Observe signup page"
    assert step.required_capability == "observe_page"

    assert {:ok, plan} = SpectreDirective.plan(pid)
    assert plan.source == :agent_generated
    assert length(plan.steps) == 1
  end

  test "create requires a mission" do
    assert {:error, :mission_required} = SpectreDirective.create(%{context: "missing goal"})
  end

  test "failing planner adapter falls back to the blueprint plan and records trace" do
    assert {:ok, pid} =
             SpectreDirective.start_mission("Recover from planner failure",
               planner: RaisingAIPlanner
             )

    assert {:ok, plan} = SpectreDirective.plan(pid)
    assert length(plan.steps) == 5

    assert {:ok, trace} = SpectreDirective.trace(pid)
    assert Enum.any?(trace, &(&1.type == :planning_failed))
  end

  test "control actions pause, resume, skip, and stop missions" do
    steps = [
      Step.new("First", kind: :observe),
      Step.new("Second", kind: :verify)
    ]

    assert {:ok, pid} =
             SpectreDirective.start_mission("Run a small mission",
               steps: steps,
               memory_adapter: FakeMemory,
               memory_opts: [parent: self()],
               capability_adapters: []
             )

    assert_receive {:recalled, "Run a small mission"}

    assert {:ok, paused} = SpectreDirective.control(pid, :pause)
    assert paused.status == :paused
    assert :resume in paused.controls

    assert {:ok, resumed} = SpectreDirective.control(pid, :resume)
    assert resumed.status == :running

    assert {:ok, skipped} = SpectreDirective.control(pid, :skip)
    assert skipped.current_step.title == "Second"

    assert {:ok, stopped} = SpectreDirective.control(pid, :stop)
    assert stopped.status == :stopped

    assert {:ok, awaited} = SpectreDirective.await(pid, 100)
    assert awaited.status == :stopped
  end

  test "risky steps wait for approval" do
    steps = [
      Step.new("Publish change", kind: :act, risk: :high, purpose: "External user-visible action")
    ]

    assert {:ok, pid} =
             SpectreDirective.start_mission("Publish after approval",
               steps: steps,
               memory_adapter: FakeMemory,
               memory_opts: [parent: self()],
               capability_adapters: []
             )

    assert_receive {:recalled, "Publish after approval"}
    assert {:ok, pulse} = SpectreDirective.pulse(pid)
    assert pulse.status == :waiting
    assert pulse.blocked?

    assert {:ok, approved} = SpectreDirective.control(pid, :approve)
    assert approved.status == :running
    assert approved.current_step.title == "Publish change"
  end
end
