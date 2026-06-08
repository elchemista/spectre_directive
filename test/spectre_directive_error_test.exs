defmodule SpectreDirectiveErrorTest do
  use ExUnit.Case

  alias SpectreDirective.Step

  defmodule OneDirective do
    use SpectreDirective

    directive "known" do
      mission("Run known directive")
      context("A test directive.")
      success("It starts.")

      step "Observe" do
        kind(:observe)
        purpose("Observe enough to start.")
      end
    end
  end

  defmodule ErrorPlanner do
    @behaviour SpectreDirective.Planner

    @impl SpectreDirective.Planner
    def draft_plan(_request, opts), do: Keyword.fetch!(opts, :reply)
  end

  test "start_directive reports modules that are not directive modules" do
    assert {:error, {:not_a_directive_module, String}} =
             SpectreDirective.start_directive(String)
  end

  test "start_directive reports missing authored directive names" do
    assert {:error, {:directive_not_found, OneDirective, "missing"}} =
             SpectreDirective.start_directive(OneDirective, directive: "missing")
  end

  test "mission lookups return not_found for unknown ids" do
    assert {:error, :not_found} = SpectreDirective.pulse("mission_missing")
    assert {:error, :not_found} = SpectreDirective.trace("mission_missing")
    assert {:error, :not_found} = SpectreDirective.capabilities("mission_missing")
    assert {:error, :not_found} = SpectreDirective.control("mission_missing", :pause)
    assert {:error, :not_found} = SpectreDirective.planning_state("mission_missing")
    assert {:error, :not_found} = SpectreDirective.propose_plan_item("mission_missing")
    assert {:error, :not_found} = SpectreDirective.submit_plan_item("mission_missing", %{})
    assert {:error, :not_found} = SpectreDirective.accept_plan_item("mission_missing")
    assert {:error, :not_found} = SpectreDirective.reject_plan_item("mission_missing", "no")
    assert {:error, :not_found} = SpectreDirective.finish_planning("mission_missing")
  end

  test "planning APIs report not_planning outside guided planning state" do
    assert {:ok, pid} =
             SpectreDirective.start_mission("Run normal mission",
               steps: [Step.new("Observe", kind: :observe, purpose: "Observe normally.")]
             )

    assert {:error, :not_planning} = SpectreDirective.planning_state(pid)
    assert {:error, :not_planning} = SpectreDirective.propose_plan_item(pid)
    assert {:error, :not_planning} = SpectreDirective.submit_plan_item(pid, %{type: :strategy})
    assert {:error, :not_planning} = SpectreDirective.accept_plan_item(pid)
    assert {:error, :not_planning} = SpectreDirective.reject_plan_item(pid, "reject")
    assert {:error, :not_planning} = SpectreDirective.finish_planning(pid)
  end

  test "guided planning requires an explicit planner before proposing" do
    assert {:ok, pid} =
             SpectreDirective.start_mission("Guided without planner", planning_mode: :guided)

    assert {:error, :planning_provider_required} = SpectreDirective.propose_plan_item(pid)
  end

  test "guided planning catches planner errors and invalid model replies" do
    assert {:ok, error_pid} =
             SpectreDirective.start_mission("Guided planner error",
               planning_mode: :guided,
               planner: ErrorPlanner,
               reply: {:error, :model_down}
             )

    assert {:error, :model_down} = SpectreDirective.propose_plan_item(error_pid)

    assert {:ok, invalid_pid} =
             SpectreDirective.start_mission("Guided invalid text",
               planning_mode: :guided,
               planner: ErrorPlanner,
               reply: {:ok, %{not: "text"}}
             )

    assert {:error, {:invalid_planning_text, %{not: "text"}}} =
             SpectreDirective.propose_plan_item(invalid_pid)
  end

  test "guided step parse errors are returned and keep planning state usable" do
    model = fn
      request, _opts when request.mode == :guided_strategy ->
        "Strategy: inspect carefully."

      request, _opts when request.mode == :guided_step ->
        send(self(), {:unexpected_self_message, request.mode})
        "This is not a step."
    end

    assert {:ok, pid} =
             SpectreDirective.start_mission("Guided parse error",
               planning_mode: :guided,
               planning_model: model
             )

    assert {:ok, _proposal} = SpectreDirective.propose_plan_item(pid)
    assert {:ok, _planning} = SpectreDirective.accept_plan_item(pid)

    assert {:error, {:guided_step_parse_failed, :no_steps}} =
             SpectreDirective.propose_plan_item(pid)

    assert {:ok, planning} = SpectreDirective.planning_state(pid)
    assert planning.pending == nil
    assert planning.steps == []
  end

  test "guided planning protects pending proposals and rejects malformed items" do
    assert {:ok, pid} =
             SpectreDirective.start_mission("Protect pending planning",
               planning_mode: :guided
             )

    assert {:error, {:invalid_plan_item, %{bad: :shape}}} =
             SpectreDirective.submit_plan_item(pid, %{bad: :shape})

    assert {:error, {:invalid_plan_item, %{type: :unknown}}} =
             SpectreDirective.submit_plan_item(pid, %{type: :unknown})

    assert {:error, :no_pending_plan_item} = SpectreDirective.accept_plan_item(pid)
    assert {:error, :no_pending_plan_item} = SpectreDirective.reject_plan_item(pid, "no")

    assert {:ok, strategy} =
             SpectreDirective.submit_plan_item(pid, %{
               type: :strategy,
               strategy: "Keep the plan small."
             })

    pending_id = strategy.id

    assert {:error, {:pending_plan_item, ^pending_id}} =
             SpectreDirective.submit_plan_item(pid, %{type: :strategy, strategy: "second"})

    assert {:error, {:pending_plan_item, ^pending_id}} = SpectreDirective.propose_plan_item(pid)

    assert {:error, {:invalid_plan_item, %{type: :step}}} =
             SpectreDirective.accept_plan_item(pid, %{type: :step})

    assert {:ok, planning} = SpectreDirective.planning_state(pid)
    assert planning.pending.id == strategy.id
    assert planning.strategy == nil

    assert {:ok, planning} = SpectreDirective.reject_plan_item(pid, "")
    assert planning.pending == nil
    assert planning.feedback == ["Proposal rejected."]
  end

  test "guided planning blocks execution APIs until planning is finished" do
    assert {:ok, pid} =
             SpectreDirective.start_mission("Planning blocks execution",
               planning_mode: :guided,
               steps: [Step.new("Fallback", kind: :observe, purpose: "Fallback step.")]
             )

    assert {:error, :planning_in_progress} = SpectreDirective.next_step(pid)
    assert {:error, :planning_in_progress} = SpectreDirective.complete_step(pid, %{summary: "no"})

    assert {:ok, pulse} = SpectreDirective.finish_planning(pid)
    assert pulse.status == :running
    assert pulse.current_step.title == "Fallback"
  end

  test "unknown control actions are ignored and traced" do
    assert {:ok, pid} =
             SpectreDirective.start_mission("Handle strange controls",
               steps: [Step.new("Observe", kind: :observe)]
             )

    assert {:ok, pulse} = SpectreDirective.control(pid, {:do_what, :unknown})
    assert pulse.status == :running

    assert {:ok, trace} = SpectreDirective.trace(pid)

    assert Enum.any?(
             trace,
             &(&1.type == :control_ignored and &1.message == "Unknown control action ignored.")
           )
  end

  test "invalid direct plan revisions are ignored and traced safely" do
    assert {:ok, pid} =
             SpectreDirective.start_mission("Handle malformed revision",
               steps: [Step.new("Observe", kind: :observe)]
             )

    assert {:ok, pulse} = SpectreDirective.control(pid, {:revise_plan, 123})
    assert pulse.status == :running
    assert pulse.current_step.title == "Observe"

    assert {:ok, trace} = SpectreDirective.trace(pid)

    assert Enum.any?(
             trace,
             &(&1.type == :control_ignored and
                 &1.message == "Invalid plan revision control ignored.")
           )
  end

  test "runtime can start and complete without any integration adapters" do
    assert {:ok, pid} =
             SpectreDirective.start_mission("No adapters",
               steps: [
                 Step.new("Observe", kind: :observe, purpose: "Observe without integrations")
               ]
             )

    assert {:ok, pulse} = SpectreDirective.pulse(pid)
    assert pulse.current_understanding =~ "No mission-relevant facts"

    assert {:ok, finished} =
             SpectreDirective.complete_step(pid, %{
               summary: "Observed enough.",
               mission_relevant_facts: ["No external integration was needed."]
             })

    assert finished.status == :finished
  end
end
