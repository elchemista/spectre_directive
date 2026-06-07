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

  test "alignment skips frontend-mission drift into backend-only work" do
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
        status: :running
      }
      |> Alignment.check(step, :pre_step)

    assert result.status == :misaligned
    assert result.recommendation == :skip
    assert result.check == :drift
  end

  test "alignment skips redundant completed work" do
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
      %{plan: plan, knowledge: Knowledge.new(nil), status: :running}
      |> Alignment.check(repeated, :pre_step)

    assert result.status == :weakly_aligned
    assert result.recommendation == :skip
    assert result.check == :redundancy
  end

  test "alignment finishes when knowledge already contains a finish-early decision" do
    step = Step.new("Verify more evidence", kind: :verify)
    knowledge = Knowledge.new(decisions: ["finish early because confidence is enough"])

    result =
      %{knowledge: knowledge, status: :running}
      |> Alignment.check(step, :post_step)

    assert result.status == :complete_enough
    assert result.recommendation == :finish
    assert result.phase == :post_step
  end
end
