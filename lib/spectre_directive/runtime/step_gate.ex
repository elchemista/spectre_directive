defmodule SpectreDirective.Runtime.StepGate do
  @moduledoc """
  Selects the next useful step and applies pre-step alignment decisions.

  This is the pre-step alignment gate from `CONCEPT.md`.

  A normal workflow runner asks "what is the next step in the list?" This module
  asks a more mission-shaped question:

      Is this pending step still worth doing now?

  Depending on alignment, the gate can start the step, skip it, pause for risk,
  block for missing capability or context, or finish early.
  """

  alias SpectreDirective.Alignment
  alias SpectreDirective.Alignment.Result
  alias SpectreDirective.Plan
  alias SpectreDirective.Runtime.State
  alias SpectreDirective.Step

  @terminal_statuses [:finished, :stopped, :aborted]
  @non_selecting_statuses [:paused, :waiting, :blocked]

  @doc """
  Selects the next pending step unless the mission cannot advance.
  """
  @spec select_next(State.t()) :: State.t()
  def select_next(%State{status: status} = state)
      when status in @terminal_statuses or status in @non_selecting_statuses do
    state
  end

  def select_next(%State{} = state) do
    state.plan
    |> Plan.next_pending()
    # Selection is always mediated by alignment. Even an authored step can be
    # skipped if current knowledge says it has drifted away from the mission.
    |> select_step(state)
  end

  @spec select_step(Step.t() | nil, State.t()) :: State.t()
  defp select_step(nil, state) do
    state
    |> State.put_status(:finished)
    |> State.add_trace(:finished, "Finished mission because no pending steps remain.")
  end

  defp select_step(%Step{} = step, state) do
    state
    |> State.to_map()
    |> Alignment.check(step, :pre_step)
    |> apply_alignment(state, step)
  end

  @spec apply_alignment(Result.t(), State.t(), Step.t()) :: State.t()
  defp apply_alignment(%Result{recommendation: :continue} = alignment, state, step) do
    state
    |> State.put_alignment(alignment)
    |> State.start_step(step)
    |> State.add_trace(:step_started, "Started step: #{step.title}", %{step_id: step.id})
  end

  defp apply_alignment(%Result{recommendation: :skip} = alignment, state, step) do
    skipped = %{step | status: :skipped, result: alignment.reason}

    state
    |> State.put_alignment(alignment)
    |> State.put_step(skipped)
    |> State.add_trace(:correction, "Skipped misaligned step: #{step.title}", alignment)
    |> select_next()
  end

  defp apply_alignment(%Result{recommendation: :pause} = alignment, state, step) do
    blocked = %{step | status: :blocked, result: alignment.reason}

    state
    |> State.put_alignment(alignment)
    |> State.put_status(:waiting)
    |> State.put_step(blocked)
    |> State.add_trace(:waiting, "Paused before risky step: #{step.title}", alignment)
  end

  defp apply_alignment(%Result{recommendation: :ask} = alignment, state, step) do
    blocked = %{step | status: :blocked, result: alignment.reason}

    state
    |> State.put_alignment(alignment)
    |> State.put_status(:blocked)
    |> State.put_step(blocked)
    |> State.add_trace(:blocked, "Blocked before step: #{step.title}", alignment)
  end

  defp apply_alignment(%Result{recommendation: :finish} = alignment, state, _step) do
    state
    |> State.put_alignment(alignment)
    |> State.put_status(:finished)
    |> State.add_trace(:finished, "Finished early: #{alignment.reason}", alignment)
  end
end
