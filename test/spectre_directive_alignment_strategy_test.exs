defmodule SpectreDirectiveAlignmentStrategyTest do
  use ExUnit.Case

  alias SpectreDirective.Alignment
  alias SpectreDirective.CapabilitySnapshot
  alias SpectreDirective.Knowledge
  alias SpectreDirective.Mission
  alias SpectreDirective.MissionBlueprint
  alias SpectreDirective.Plan
  alias SpectreDirective.Step
  alias SpectreDirective.Strategies

  defmodule SkipBackendAlignment do
    @behaviour SpectreDirective.Alignment

    @impl SpectreDirective.Alignment
    def check_alignment(request, _opts) do
      send(
        self(),
        {:alignment_request, request.phase, request.step.title, request.strategies,
         request.prompt}
      )

      %{
        status: :misaligned,
        recommendation: :skip,
        check: :drift,
        score: 0.12,
        reason: "The model judged this backend-only step as drift for a frontend mission."
      }
    end
  end

  defmodule RedundantAlignment do
    @behaviour SpectreDirective.Alignment

    @impl SpectreDirective.Alignment
    def check_alignment(_request, _opts) do
      {:ok,
       %SpectreDirective.Alignment.Result{
         status: :weakly_aligned,
         recommendation: :skip,
         check: :redundancy,
         score: 0.94,
         reason: "The model judged this step redundant."
       }}
    end
  end

  defmodule FinishAlignment do
    @behaviour SpectreDirective.Alignment

    @impl SpectreDirective.Alignment
    def check_alignment(_request, _opts) do
      [
        status: :complete_enough,
        recommendation: :finish,
        check: :confidence,
        score: 0.91,
        reason: "The model judged the mission complete enough."
      ]
    end
  end

  defmodule FailingAlignment do
    @behaviour SpectreDirective.Alignment

    @impl SpectreDirective.Alignment
    def check_alignment(_request, _opts), do: raise("alignment model unavailable")
  end

  test "alignment request carries authored rules, plan state, knowledge, and prompt text" do
    current =
      Step.new("Currently running",
        kind: :observe,
        purpose: "Inspect current state",
        status: :running
      )

    completed =
      Step.new("Already verified",
        kind: :verify,
        purpose: "Verify an earlier fact",
        status: :completed
      )

    skipped =
      Step.new("Skipped detour",
        kind: :investigate,
        purpose: "Low-value detour",
        status: :skipped
      )

    next_step =
      Step.new("Next useful action",
        kind: :act,
        purpose: "Take the next useful action",
        required_capability: :browser
      )

    plan =
      Plan.new(%{
        steps: [completed, skipped, current, next_step],
        completed_steps: [completed],
        skipped_steps: [skipped],
        current_step_id: current.id
      })

    blueprint =
      MissionBlueprint.new(
        name: "rich-alignment",
        mission: Mission.new("Keep the agent on mission"),
        strategies: [:qa_flow],
        capability_rules: %{required: [:browser], allowed: [:browser], denied: [:payment]},
        alignment_rules: [{:mission_relevance, [min_score: 0.8]}],
        correction_rules: [{:prefer, :small_safe_moves}],
        plan: plan
      )

    knowledge =
      Mission.new("Keep the agent on mission")
      |> Knowledge.new()
      |> Map.put(:known_facts, ["The page is loaded."])
      |> Map.put(:mission_relevant_facts, ["The signup route is visible."])
      |> Map.put(:decisions, ["Do not use real payments."])

    request =
      SpectreDirective.Alignment.Request.new(
        %{
          blueprint: blueprint,
          plan: plan,
          knowledge: knowledge,
          capabilities:
            CapabilitySnapshot.new([
              %{name: :browser, description: "Browser automation", risk: :medium}
            ]),
          status: :running
        },
        next_step,
        :post_step
      )

    assert request.status == :running
    assert request.strategies == Strategies.expand([:qa_flow])
    assert request.alignment_rules == [{:mission_relevance, [min_score: 0.8]}]
    assert request.correction_rules == [{:prefer, :small_safe_moves}]
    assert request.capability_rules.denied == [:payment]
    assert request.current_step.title == "Currently running"
    assert request.next_step.title == "Next useful action"
    assert Enum.map(request.completed_steps, & &1.title) == ["Already verified"]
    assert Enum.map(request.skipped_steps, & &1.title) == ["Skipped detour"]

    assert request.prompt =~ "Alignment rules"
    assert request.prompt =~ "Correction rules"
    assert request.prompt =~ "Capability rules"
    assert request.prompt =~ "Currently running"
    assert request.prompt =~ "Next useful action"
    assert request.prompt =~ "Already verified"
    assert request.prompt =~ "Skipped detour"
    assert request.prompt =~ "The signup route is visible."
    assert request.prompt =~ "browser"
  end

  test "strategy presets expand to ordered unique primitive strategies" do
    assert Strategies.expand([:qa_flow, :safe_operator, :custom_strategy]) == [
             :observe_before_act,
             :verify_after_act,
             :small_safe_moves,
             :learn_every_step,
             :finish_when_enough,
             :pause_before_impact,
             :custom_strategy
           ]
  end

  test "strategy presets only contain declared primitive strategies" do
    primitive = Strategies.primitive()

    Strategies.presets()
    |> Enum.each(fn {_preset, strategies} ->
      assert Enum.all?(strategies, &(&1 in primitive))
    end)
  end

  test "alignment pauses high risk steps until approved" do
    step = Step.new("Publish release", kind: :act, risk: :high)

    result =
      %{approvals: MapSet.new(), knowledge: Knowledge.new(nil), status: :running}
      |> Alignment.check(step, :pre_step)

    assert result.status == :risky
    assert result.recommendation == :pause

    approved =
      %{approvals: MapSet.new([step.id]), knowledge: Knowledge.new(nil), status: :running}
      |> Alignment.check(step, :pre_step)

    assert approved.status == :aligned
    assert approved.recommendation == :continue
  end

  test "alignment blocks when a required capability is missing" do
    step =
      Step.new("Inspect repository",
        kind: :investigate,
        required_capability: :inspect_repository
      )

    result =
      %{
        capabilities: CapabilitySnapshot.new([]),
        knowledge: Knowledge.new(nil),
        status: :running
      }
      |> Alignment.check(step, :pre_step)

    assert result.status == :blocked
    assert result.recommendation == :ask
    assert result.check == :capability
  end

  test "alignment module can skip frontend-mission drift into backend-only work" do
    mission =
      Mission.new(%{
        goal: "Evaluate React frontend fit",
        context: "Frontend evidence matters. Backend evidence is secondary.",
        success: "React and UI evidence is summarized."
      })

    step =
      Step.new("Deep inspect backend service",
        kind: :investigate,
        purpose: "Review backend-only implementation details"
      )

    result =
      %{
        blueprint: MissionBlueprint.new(name: "fit", mission: mission, steps: [step]),
        knowledge: Knowledge.new(mission),
        status: :running,
        opts: [alignment: SkipBackendAlignment]
      }
      |> Alignment.check(step, :pre_step)

    assert result.status == :misaligned
    assert result.recommendation == :skip
    assert result.check == :drift
    assert result.metadata.alignment == SkipBackendAlignment

    assert_receive {:alignment_request, :pre_step, "Deep inspect backend service", strategies,
                    prompt}

    assert strategies == []
    assert prompt =~ "Evaluate React frontend fit"
    assert prompt =~ "Deep inspect backend service"
  end

  test "alignment module can use strategy context and skip redundant completed work" do
    completed =
      Step.new("Summarize signup blockers",
        kind: :summarize,
        purpose: "List current signup blockers",
        status: :completed
      )

    repeated =
      Step.new("Summarize signup blockers",
        kind: :summarize,
        purpose: "List current signup blockers"
      )

    plan = Plan.new(%{steps: [completed, repeated], completed_steps: [completed]})

    result =
      %{
        blueprint:
          MissionBlueprint.new(
            name: "signup",
            mission: Mission.new("Check signup"),
            strategies: [:qa_flow],
            steps: [repeated]
          ),
        plan: plan,
        knowledge: Knowledge.new(nil),
        status: :running,
        opts: [alignment: RedundantAlignment]
      }
      |> Alignment.check(repeated, :pre_step)

    assert result.status == :weakly_aligned
    assert result.recommendation == :skip
    assert result.check == :redundancy
    assert result.metadata.alignment == RedundantAlignment
  end

  test "alignment module can finish when it judges confidence complete enough" do
    step = Step.new("Verify more evidence", kind: :verify)

    result =
      %{knowledge: Knowledge.new(nil), status: :running, opts: [alignment: FinishAlignment]}
      |> Alignment.check(step, :post_step)

    assert result.status == :complete_enough
    assert result.recommendation == :finish
    assert result.phase == :post_step
    assert result.metadata.alignment == FinishAlignment
  end

  test "alignment falls back to review when alignment module fails" do
    step = Step.new("Publish release", kind: :act)

    result =
      %{knowledge: Knowledge.new(nil), status: :running, opts: [alignment: FailingAlignment]}
      |> Alignment.check(step, :pre_step)

    assert result.status == :blocked
    assert result.recommendation == :ask
    assert result.check == :alignment
    assert result.metadata.alignment == FailingAlignment
    assert {:alignment_failed, FailingAlignment, _error} = result.metadata.alignment_error
  end
end
