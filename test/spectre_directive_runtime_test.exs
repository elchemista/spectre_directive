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

  defmodule RuntimeAlignment do
    @behaviour SpectreDirective.Alignment

    @impl SpectreDirective.Alignment
    def check_alignment(request, opts) do
      send(opts[:parent], {:runtime_alignment, request.phase, request.step && request.step.title})

      case request.step && request.step.title do
        "Skip by model" ->
          %{
            status: :misaligned,
            recommendation: :skip,
            check: :drift,
            reason: "Alignment model skipped this step."
          }

        "Revise by model" ->
          %{
            status: :blocked,
            recommendation: :revise,
            check: :strategy,
            reason: "Alignment model wants the plan revised first."
          }

        _title ->
          %{
            status: :aligned,
            recommendation: :continue,
            check: :mission_relevance,
            reason: "Alignment model allowed this step."
          }
      end
    end
  end

  defmodule PostStepAlignment do
    @behaviour SpectreDirective.Alignment

    @impl SpectreDirective.Alignment
    def check_alignment(request, opts) do
      send(
        opts[:parent],
        {:post_step_alignment, request.phase, request.step && request.step.title}
      )

      recommendation =
        if request.phase == :post_step do
          Keyword.fetch!(opts, :post_step_recommendation)
        else
          :continue
        end

      %{
        status: status_for(recommendation),
        recommendation: recommendation,
        check: :strategy,
        reason: "Post-step alignment chose #{recommendation}."
      }
    end

    defp status_for(:continue), do: :aligned
    defp status_for(:skip), do: :misaligned
    defp status_for(:pause), do: :risky
    defp status_for(:ask), do: :blocked
    defp status_for(:revise), do: :blocked
    defp status_for(:stop), do: :blocked
    defp status_for(:finish), do: :complete_enough
  end

  defmodule ResearchAlignment do
    @behaviour SpectreDirective.Alignment

    @impl SpectreDirective.Alignment
    def check_alignment(request, _opts) do
      if request.step.title =~ "backend" do
        %{
          status: :misaligned,
          recommendation: :skip,
          check: :drift,
          reason: "Alignment model judged backend-only work as drift."
        }
      else
        %{
          status: :aligned,
          recommendation: :continue,
          check: :mission_relevance,
          reason: "Alignment model judged the step relevant."
        }
      end
    end
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
               alignment: ResearchAlignment,
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

  test "guided planning is manually driven through OTP calls" do
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
          Step: Rough observation
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
               capabilities: [
                 %{name: :observe_page, description: "Observe the current browser page."}
               ],
               planning_subscribers: [parent]
             )

    assert {:ok, pulse} = SpectreDirective.pulse(pid)
    assert pulse.status == :planning
    assert {:error, :planning_in_progress} = SpectreDirective.next_step(pid)

    assert {:ok, planning} = SpectreDirective.planning_state(pid)
    assert planning.steps == []
    assert planning.pending == nil

    assert {:ok, strategy} = SpectreDirective.propose_plan_item(pid)
    assert_receive {:guided_prompt, 0, strategy_prompt}
    assert strategy_prompt =~ "Do not write steps yet"
    assert strategy.type == :strategy
    assert strategy.strategy =~ "observe first"
    assert_receive {:spectre_directive, _mission_id, :planning_proposal, ^strategy}

    assert {:ok, planning} = SpectreDirective.accept_plan_item(pid)
    assert planning.strategy =~ "observe first"

    assert {:ok, rough_step} = SpectreDirective.propose_plan_item(pid)
    assert_receive {:guided_prompt, 1, first_step_prompt}
    assert first_step_prompt =~ "Generate only step 1"
    assert first_step_prompt =~ "Steps already generated:\n-"
    assert rough_step.type == :step
    assert rough_step.step.title == "Rough observation"

    assert {:ok, planning} =
             SpectreDirective.accept_plan_item(pid, %{
               type: :step,
               step: %{
                 title: "Edited guided observation",
                 kind: :observe,
                 purpose: "Inspect the visible signup entry before acting.",
                 capability: :observe_page
               }
             })

    assert Enum.map(planning.steps, & &1.title) == ["Edited guided observation"]

    assert {:ok, second_step} = SpectreDirective.propose_plan_item(pid)
    assert second_step.step.title == "Guided verification"

    assert {:ok, planning} =
             SpectreDirective.reject_plan_item(pid, "Need a smaller verification.")

    assert planning.feedback == ["Need a smaller verification."]

    assert {:ok, finish} = SpectreDirective.propose_plan_item(pid)
    assert_receive {:guided_prompt, 2, second_step_prompt}
    assert second_step_prompt =~ "Generate only step 2"
    assert second_step_prompt =~ "Edited guided observation"
    assert_receive {:guided_prompt, 3, finish_prompt}
    assert finish_prompt =~ "Need a smaller verification."
    assert finish.type == :finish
    assert {:ok, _planning} = SpectreDirective.accept_plan_item(pid)

    assert {:ok, pulse} = SpectreDirective.finish_planning(pid)
    assert pulse.status == :running
    assert pulse.current_step.title == "Edited guided observation"
    assert {:ok, plan} = SpectreDirective.plan(pid)
    assert Enum.map(plan.steps, & &1.title) == ["Edited guided observation"]

    assert {:ok, trace} = SpectreDirective.trace(pid)
    assert Enum.any?(trace, &(&1.type == :planned and &1.data.mode == :guided))
  end

  test "external processes can submit guided planning items" do
    parent = self()

    assert {:ok, pid} =
             SpectreDirective.start_mission("Plan from another process",
               planning_mode: :guided,
               planning_subscribers: [parent]
             )

    assert {:ok, strategy} =
             SpectreDirective.submit_plan_item(pid, %{
               type: :strategy,
               strategy: "Let a supervising process build the plan."
             })

    assert strategy.type == :strategy
    assert_receive {:spectre_directive, _mission_id, :planning_proposal, ^strategy}

    assert {:ok, planning} = SpectreDirective.accept_plan_item(pid)
    assert planning.strategy =~ "supervising process"

    assert {:ok, step} =
             SpectreDirective.submit_plan_item(pid, %{
               type: :step,
               step: %{
                 title: "Externally proposed step",
                 kind: :investigate,
                 purpose: "Use an external process proposal."
               }
             })

    assert step.step.title == "Externally proposed step"
    assert {:ok, planning} = SpectreDirective.accept_plan_item(pid)
    assert Enum.map(planning.steps, & &1.title) == ["Externally proposed step"]

    assert {:ok, pulse} = SpectreDirective.finish_planning(pid, "External process approved plan.")
    assert pulse.status == :running
    assert pulse.current_step.title == "Externally proposed step"
  end

  test "create starts a manually guided mission from one simple agent map" do
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

    assert {:ok, pulse} = SpectreDirective.pulse(pid)
    assert pulse.status == :planning

    assert {:ok, strategy} = SpectreDirective.propose_plan_item(pid)
    assert_receive {:create_prompt, 0, strategy_prompt}
    assert strategy_prompt =~ "Make sure a new user can finish sign up"
    assert strategy_prompt =~ "observe_page"
    assert strategy.type == :strategy
    assert {:ok, _planning} = SpectreDirective.accept_plan_item(pid)

    assert {:ok, step_proposal} = SpectreDirective.propose_plan_item(pid)
    assert_receive {:create_prompt, 1, step_prompt}
    assert step_prompt =~ "Generate only step 1"
    assert step_proposal.step.title == "Observe signup page"
    assert {:ok, _planning} = SpectreDirective.accept_plan_item(pid)

    assert {:ok, finish} = SpectreDirective.propose_plan_item(pid)
    assert_receive {:create_prompt, 2, finish_prompt}
    assert finish_prompt =~ "Observe signup page"
    assert finish.type == :finish
    assert {:ok, _planning} = SpectreDirective.accept_plan_item(pid)

    assert {:ok, _pulse} = SpectreDirective.finish_planning(pid)
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

  test "runtime uses custom alignment module to control step selection" do
    steps = [
      Step.new("Skip by model", kind: :investigate, purpose: "Model should skip this."),
      Step.new("Continue by model", kind: :observe, purpose: "Model should allow this."),
      Step.new("Revise by model", kind: :act, purpose: "Model should request revision.")
    ]

    assert {:ok, pid} =
             SpectreDirective.start_mission("Run with model alignment",
               steps: steps,
               alignment: RuntimeAlignment,
               parent: self()
             )

    assert_receive {:runtime_alignment, :pre_step, "Skip by model"}
    assert_receive {:runtime_alignment, :pre_step, "Continue by model"}

    assert {:ok, pulse} = SpectreDirective.pulse(pid)
    assert pulse.status == :running
    assert pulse.current_step.title == "Continue by model"

    assert {:ok, pulse} =
             SpectreDirective.complete_step(pid, %{
               summary: "Allowed step completed."
             })

    assert_receive {:runtime_alignment, :post_step, "Revise by model"}
    assert pulse.status == :blocked
    assert pulse.current_step == nil
    assert pulse.alignment.recommendation == :revise

    assert {:ok, trace} = SpectreDirective.trace(pid)
    assert Enum.any?(trace, &(&1.message =~ "Skipped misaligned step: Skip by model"))
    assert Enum.any?(trace, &(&1.message =~ "Alignment requested plan revision"))
  end

  test "post-step alignment recommendations actively update mission state" do
    cases = [
      {:continue, :running, "Second"},
      {:skip, :running, "Third"},
      {:pause, :waiting, nil},
      {:ask, :blocked, nil},
      {:revise, :blocked, nil},
      {:stop, :stopped, nil},
      {:finish, :finished, nil}
    ]

    Enum.each(cases, fn {recommendation, expected_status, expected_current_title} ->
      steps = [
        Step.new("First", kind: :observe, purpose: "Complete first."),
        Step.new("Second", kind: :verify, purpose: "Post-step alignment targets this."),
        Step.new("Third", kind: :summarize, purpose: "Used after skip.")
      ]

      assert {:ok, pid} =
               SpectreDirective.start_mission("Post-step #{recommendation}",
                 steps: steps,
                 alignment: PostStepAlignment,
                 post_step_recommendation: recommendation,
                 parent: self()
               )

      assert_receive {:post_step_alignment, :pre_step, "First"}

      assert {:ok, pulse} =
               SpectreDirective.complete_step(pid, %{
                 summary: "First step completed."
               })

      assert_receive {:post_step_alignment, :post_step, "Second"}
      assert pulse.status == expected_status, "recommendation: #{recommendation}"

      if expected_current_title do
        assert pulse.current_step.title == expected_current_title
      else
        assert pulse.current_step == nil
      end

      assert {:ok, trace} = SpectreDirective.trace(pid)

      expected_trace_type =
        case recommendation do
          :continue -> :step_started
          :skip -> :correction
          :pause -> :waiting
          :ask -> :blocked
          :revise -> :blocked
          :stop -> :stopped
          :finish -> :finished
        end

      assert Enum.any?(trace, &(&1.type == expected_trace_type))
    end)
  end

  test "host loop can inspect capabilities, handle revise block, patch the living plan, and resume" do
    steps = [
      Step.new("Continue by model", kind: :observe, purpose: "Allowed first step."),
      Step.new("Revise by model", kind: :act, purpose: "Blocked until reviewer revises."),
      Step.new("Final by model", kind: :verify, purpose: "Continue after correction.")
    ]

    assert {:ok, pid} =
             SpectreDirective.start_mission("Host-driven loop",
               steps: steps,
               capability_adapters: [FakeLens],
               alignment: RuntimeAlignment,
               parent: self()
             )

    assert_receive :lens_discovered

    assert {:ok, capabilities} = SpectreDirective.capabilities(pid)
    assert Enum.any?(capabilities.capabilities, &(&1.name == :observe_page))

    assert {:ok, pulse} = SpectreDirective.pulse(pid)
    assert pulse.current_step.title == "Continue by model"

    assert {:ok, blocked} =
             SpectreDirective.complete_step(pid, %{
               summary: "First host-executed step completed."
             })

    assert_receive {:runtime_alignment, :post_step, "Revise by model"}
    assert blocked.status == :blocked
    assert :revise_plan in blocked.controls

    assert {:ok, resumed} =
             SpectreDirective.control(pid, {
               :revise_plan,
               %{
                 type: :remove_steps,
                 strategy: :strategic,
                 reason: "Reviewer removed the blocked step from the living plan.",
                 changes: %{matching: "Revise by model"}
               }
             })

    assert resumed.status == :running
    assert resumed.current_step.title == "Final by model"

    assert {:ok, final} =
             SpectreDirective.complete_step(pid, %{
               summary: "Final step completed.",
               decisions: ["finish early because final verification is enough"]
             })

    assert final.status == :finished

    assert {:ok, plan} = SpectreDirective.plan(pid)
    refute Enum.any?(plan.steps, &(&1.title == "Revise by model"))
  end

  test "mock executor runs steps and lets corrections revise the plan" do
    steps = [
      Step.new("Check signup entry",
        kind: :observe,
        purpose: "Inspect the signup entry before acting.",
        expected_output: "Signup entry evidence.",
        done_condition: "A blocker or success state is identified."
      )
    ]

    assert {:ok, pid} =
             SpectreDirective.start_mission("Execute signup plan with mock model",
               steps: steps,
               capability_adapters: []
             )

    assert run_mock_executor(pid, self()) == ["Check signup entry", "Inspect signup blocker"]

    assert_receive {:mock_asserted, "Check signup entry",
                    "A blocker or success state is identified."}

    assert_receive {:mock_asserted, "Inspect signup blocker", "The blocker is understood."}

    assert {:ok, pulse} = SpectreDirective.pulse(pid)
    assert pulse.status == :finished
    assert pulse.current_understanding =~ "Email verification blocks signup completion."

    assert {:ok, plan} = SpectreDirective.plan(pid)
    assert plan.version == 3
    assert Enum.map(plan.steps, & &1.title) == ["Check signup entry", "Inspect signup blocker"]

    assert Enum.map(plan.revision_history, & &1.reason) == [
             "Signup entry exposed a blocker.",
             "Blocker understood well enough to finish."
           ]
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

  defp run_mock_executor(pid, parent, executed \\ []) do
    case SpectreDirective.pulse(pid) do
      {:ok, %{status: status}} when status in [:finished, :stopped, :aborted] ->
        Enum.reverse(executed)

      {:ok, _pulse} ->
        {:ok, step} = SpectreDirective.next_step(pid)
        observation = mock_model_observation(step, parent)
        {:ok, _pulse} = SpectreDirective.complete_step(pid, observation)
        run_mock_executor(pid, parent, [step.title | executed])
    end
  end

  defp mock_model_observation(%Step{title: "Check signup entry"} = step, parent) do
    assert_step_contract!(step, "A blocker or success state is identified.", parent)

    %{
      summary: "Signup entry is visible but email verification blocks completion.",
      evidence: ["Verification banner is visible after signup submit."],
      mission_relevant_facts: ["Email verification blocks signup completion."],
      correction: %{
        type: :add_step,
        strategy: :tactical,
        reason: "Signup entry exposed a blocker.",
        changes: %{
          step: %{
            title: "Inspect signup blocker",
            kind: :investigate,
            purpose: "Understand the email verification blocker before finishing.",
            expected_output: "Verification blocker details.",
            done_condition: "The blocker is understood."
          }
        }
      }
    }
  end

  defp mock_model_observation(%Step{title: "Inspect signup blocker"} = step, parent) do
    assert_step_contract!(step, "The blocker is understood.", parent)

    %{
      summary: "The blocker is email verification, not form validation.",
      evidence: ["Verification email requirement appears after submit."],
      mission_relevant_facts: ["Signup can proceed only after email verification."],
      decisions: ["finish early because the blocker is understood"],
      correction: %{
        type: :finish_early,
        strategy: :confidence,
        reason: "Blocker understood well enough to finish."
      }
    }
  end

  defp assert_step_contract!(%Step{} = step, done_condition, parent) do
    assert step.done_condition == done_condition
    send(parent, {:mock_asserted, step.title, step.done_condition})
  end
end
