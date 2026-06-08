defmodule SpectreDirective.Runtime.AlignmentGate do
  @moduledoc """
  Applies alignment recommendations to live mission state.

  Pre-step and post-step alignment both use the same recommendation vocabulary.
  Keeping the mechanical effects here prevents the two gates from drifting:
  continue, skip, pause, ask, revise, stop, and finish all leave pulse and trace
  in the same shape no matter which phase produced the judgment.
  """

  alias SpectreDirective.Alignment.Result
  alias SpectreDirective.Runtime.State
  alias SpectreDirective.Runtime.StepGate
  alias SpectreDirective.Step

  @type phase :: :pre_step | :post_step

  @doc """
  Applies an alignment result to the targeted step.
  """
  @spec apply(Result.t(), State.t(), Step.t() | nil, phase()) :: State.t()
  def apply(%Result{recommendation: :continue} = alignment, state, %Step{} = step, :pre_step) do
    state
    |> State.put_alignment(alignment)
    |> State.start_step(step)
    |> State.add_trace(:step_started, "Started step: #{step.title}", %{step_id: step.id})
  end

  def apply(%Result{recommendation: :continue} = alignment, state, _step, :post_step) do
    State.put_alignment(state, alignment)
  end

  def apply(%Result{recommendation: recommendation} = alignment, state, nil, _phase)
      when recommendation in [:skip, :pause, :ask, :revise] do
    state
    |> State.put_alignment(alignment)
    |> State.put_status(:blocked)
    |> State.add_trace(:blocked, "Alignment blocked with no pending step.", alignment)
  end

  def apply(%Result{recommendation: :skip} = alignment, state, %Step{} = step, :pre_step) do
    state
    |> skip_step(alignment, step)
    |> StepGate.select_next()
  end

  def apply(%Result{recommendation: :skip} = alignment, state, %Step{} = step, :post_step) do
    skip_step(state, alignment, step)
  end

  def apply(%Result{recommendation: :pause} = alignment, state, %Step{} = step, _phase) do
    blocked = %{step | status: :blocked, result: alignment.reason}

    state
    |> State.put_alignment(alignment)
    |> State.put_status(:waiting)
    |> State.put_step(blocked)
    |> State.add_trace(:waiting, "Paused before risky step: #{step.title}", alignment)
  end

  def apply(%Result{recommendation: :ask} = alignment, state, %Step{} = step, _phase) do
    blocked = %{step | status: :blocked, result: alignment.reason}

    state
    |> State.put_alignment(alignment)
    |> State.put_status(:blocked)
    |> State.put_step(blocked)
    |> State.add_trace(:blocked, "Blocked before step: #{step.title}", alignment)
  end

  def apply(%Result{recommendation: :revise} = alignment, state, %Step{} = step, _phase) do
    blocked = %{step | status: :blocked, result: alignment.reason}

    state
    |> State.put_alignment(alignment)
    |> State.put_status(:blocked)
    |> State.put_step(blocked)
    |> State.add_trace(
      :blocked,
      "Alignment requested plan revision before step: #{step.title}",
      alignment
    )
  end

  def apply(%Result{recommendation: :stop} = alignment, state, _step, _phase) do
    state
    |> State.put_alignment(alignment)
    |> State.put_status(:stopped)
    |> State.add_trace(:stopped, "Stopped by alignment: #{alignment.reason}", alignment)
  end

  def apply(%Result{recommendation: :finish} = alignment, state, _step, _phase) do
    state
    |> State.put_alignment(alignment)
    |> State.put_status(:finished)
    |> State.add_trace(:finished, "Finished early: #{alignment.reason}", alignment)
  end

  @spec skip_step(State.t(), Result.t(), Step.t()) :: State.t()
  defp skip_step(state, alignment, step) do
    skipped = %{step | status: :skipped, result: alignment.reason}

    state
    |> State.put_alignment(alignment)
    |> State.put_step(skipped)
    |> State.add_trace(:correction, "Skipped misaligned step: #{step.title}", alignment)
  end
end
