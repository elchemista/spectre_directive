defmodule SpectreDirective.Runtime.PlanReviser do
  @moduledoc """
  Applies post-step corrections to runtime state.

  Correction is the part of SpectreDirective that makes the plan alive. The
  first plan is only the best guess available at mission start. After each
  observation, a correction can keep the plan, finish early, abort, add steps,
  remove stale work, or record a revision.

  Every plan-changing correction increments the plan version and stores a
  revision reason. That is what lets `trace/1` and `plan/1` answer not only
  "what changed?" but "why did the plan change?"
  """

  alias SpectreDirective.Alignment
  alias SpectreDirective.Correction
  alias SpectreDirective.Impact
  alias SpectreDirective.Observation
  alias SpectreDirective.Plan
  alias SpectreDirective.Runtime.AlignmentGate
  alias SpectreDirective.Runtime.State
  alias SpectreDirective.Step

  @doc """
  Applies a correction emitted by a completed step observation.
  """
  @spec apply(State.t(), Correction.t(), Observation.t(), Impact.t()) :: State.t()
  def apply(%State{} = state, %Correction{type: :continue}, %Observation{}, %Impact{}) do
    align_next_pending(state)
  end

  def apply(
        %State{} = state,
        %Correction{type: :finish_early} = correction,
        %Observation{},
        %Impact{}
      ) do
    state
    |> State.put_status(:finished)
    |> revise_plan(correction)
    |> State.add_trace(:correction, "Finished early: #{correction.reason}", correction)
  end

  def apply(%State{} = state, %Correction{type: :abort} = correction, %Observation{}, %Impact{}) do
    state
    |> State.put_status(:aborted)
    |> revise_plan(correction)
    |> State.add_trace(:correction, "Aborted mission: #{correction.reason}", correction)
  end

  def apply(
        %State{} = state,
        %Correction{type: :add_step} = correction,
        %Observation{},
        %Impact{}
      ) do
    correction.changes
    |> correction_step()
    |> add_step(state, correction)
    |> align_next_pending()
  end

  def apply(
        %State{} = state,
        %Correction{type: :remove_steps} = correction,
        %Observation{},
        %Impact{}
      ) do
    correction.changes
    |> matching_text()
    |> remove_matching_steps(state, correction)
    |> align_next_pending()
  end

  def apply(%State{} = state, %Correction{} = correction, %Observation{}, %Impact{}) do
    revise_plan(state, correction)
    |> align_next_pending()
  end

  @doc """
  Applies a direct plan revision supplied by a control action.
  """
  @spec apply_revision(State.t(), Correction.t()) :: State.t()
  def apply_revision(%State{} = state, %Correction{type: :finish_early} = correction) do
    state
    |> State.put_status(:finished)
    |> revise_plan(correction)
    |> State.add_trace(:correction, "Finished early: #{correction.reason}", correction)
  end

  def apply_revision(%State{} = state, %Correction{type: :abort} = correction) do
    state
    |> State.put_status(:aborted)
    |> revise_plan(correction)
    |> State.add_trace(:correction, "Aborted mission: #{correction.reason}", correction)
  end

  def apply_revision(%State{} = state, %Correction{type: :add_step} = correction) do
    correction.changes
    |> correction_step()
    |> add_step(state, correction)
    |> align_next_pending()
  end

  def apply_revision(%State{} = state, %Correction{type: :remove_steps} = correction) do
    correction.changes
    |> matching_text()
    |> remove_matching_steps(state, correction)
    |> align_next_pending()
  end

  def apply_revision(%State{} = state, %Correction{} = correction) do
    state
    |> revise_plan(correction)
    |> align_next_pending()
  end

  @spec revise_plan(State.t(), Correction.t()) :: State.t()
  defp revise_plan(%State{} = state, %Correction{} = correction) do
    State.put_plan(state, Plan.revise(state.plan, correction.reason, correction))
  end

  @spec correction_step(map()) :: Step.t() | map() | nil
  defp correction_step(changes) do
    Map.get(changes, :step) || Map.get(changes, "step")
  end

  @spec add_step(Step.t() | map() | nil, State.t(), Correction.t()) :: State.t()
  defp add_step(nil, state, _correction), do: state

  defp add_step(step, state, correction) do
    State.put_plan(state, Plan.add_step(state.plan, step, correction.reason))
  end

  @spec matching_text(map()) :: binary()
  defp matching_text(changes) do
    changes
    |> Map.get(:matching, Map.get(changes, "matching", ""))
    |> to_string()
  end

  @spec remove_matching_steps(binary(), State.t(), Correction.t()) :: State.t()
  defp remove_matching_steps("", state, _correction), do: state

  defp remove_matching_steps(text, state, correction) do
    predicate = fn step -> step_matches_text?(step, text) end
    State.put_plan(state, Plan.remove_matching(state.plan, predicate, correction.reason))
  end

  @spec align_next_pending(State.t()) :: State.t()
  defp align_next_pending(%State{status: status} = state)
       when status in [:finished, :stopped, :aborted, :planning, :paused, :waiting, :blocked] do
    state
  end

  defp align_next_pending(%State{} = state) do
    step = Plan.next_pending(state.plan)

    state
    |> State.to_map()
    |> Alignment.check(step, :post_step)
    |> AlignmentGate.apply(state, step, :post_step)
  end

  @spec step_matches_text?(Step.t(), binary()) :: boolean()
  defp step_matches_text?(%Step{} = step, text) do
    step_text =
      [step.title, step.purpose]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    String.contains?(step_text, String.downcase(text))
  end
end
