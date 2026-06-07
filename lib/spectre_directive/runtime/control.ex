defmodule SpectreDirective.Runtime.Control do
  @moduledoc """
  Applies human or supervising-agent control actions to a mission.
  """

  alias SpectreDirective.Plan
  alias SpectreDirective.Runtime.State
  alias SpectreDirective.Runtime.StepGate
  alias SpectreDirective.Step

  @terminal_statuses [:finished, :stopped, :aborted]

  @doc """
  Applies one supported control action.
  """
  @spec apply_action(State.t(), term()) :: State.t()
  def apply_action(%State{status: status} = state, _action) when status in @terminal_statuses,
    do: state

  def apply_action(%State{} = state, :pause) do
    state
    |> State.put_status(:paused)
    |> State.add_trace(:control, "Mission paused.")
  end

  def apply_action(%State{} = state, :resume) do
    state
    |> State.put_status(:running)
    |> State.add_trace(:control, "Mission resumed.")
    |> continue_after_resume()
  end

  def apply_action(%State{} = state, :stop) do
    state
    |> State.put_status(:stopped)
    |> State.add_trace(:control, "Mission stopped.")
  end

  def apply_action(%State{} = state, action) when action in [:finish, :finish_early] do
    state
    |> State.put_status(:finished)
    |> State.add_trace(:control, "Mission finished early by control action.")
  end

  def apply_action(%State{} = state, {:skip, step_id}) when is_binary(step_id) do
    state
    |> update_step_status(step_id, :skipped, "Skipped by control action.")
    |> State.add_trace(:control, "Skipped step #{step_id}.")
    |> StepGate.select_next()
  end

  def apply_action(%State{} = state, :skip) do
    state.plan
    |> Plan.current_step()
    |> skip_current_step(state)
  end

  def apply_action(%State{} = state, {:approve, step_id}) when is_binary(step_id) do
    state
    |> State.approve_step(step_id)
    |> State.put_status(:running)
    |> unblock_current_step()
    |> State.add_trace(:control, "Approved step #{step_id}.")
    |> StepGate.select_next()
  end

  def apply_action(%State{} = state, :approve) do
    state
    |> approvable_step()
    |> approve_step(state)
  end

  def apply_action(%State{} = state, {:reject, step_id}) when is_binary(step_id),
    do: apply_action(state, {:skip, step_id})

  def apply_action(%State{} = state, {:revise_context, context}) when is_binary(context) do
    state
    |> State.put_context(context)
    |> State.add_trace(:control, "Mission context revised.", context)
    |> StepGate.select_next()
  end

  def apply_action(%State{} = state, :retry) do
    state.plan
    |> Plan.current_step()
    |> retry_step(state)
  end

  def apply_action(%State{} = state, action) do
    State.add_trace(state, :control_ignored, "Unknown control action ignored.", action)
  end

  @spec skip_current_step(Step.t() | nil, State.t()) :: State.t()
  defp skip_current_step(nil, state), do: state
  defp skip_current_step(%Step{id: step_id}, state), do: apply_action(state, {:skip, step_id})

  @spec approve_step(Step.t() | nil, State.t()) :: State.t()
  defp approve_step(nil, state), do: state
  defp approve_step(%Step{id: step_id}, state), do: apply_action(state, {:approve, step_id})

  @spec retry_step(Step.t() | nil, State.t()) :: State.t()
  defp retry_step(nil, state), do: StepGate.select_next(state)

  defp retry_step(%Step{} = step, state) do
    retried = %{step | status: :running, attempts: step.attempts + 1}

    state
    |> State.put_step(retried)
    |> State.add_trace(:control, "Retrying step: #{step.title}", %{step_id: step.id})
  end

  @spec update_step_status(State.t(), binary(), Step.status(), term()) :: State.t()
  defp update_step_status(state, step_id, status, result) do
    state.plan.steps
    |> Enum.find(&(&1.id == step_id))
    |> put_step_status(state, step_id, status, result)
  end

  @spec put_step_status(Step.t() | nil, State.t(), binary(), Step.status(), term()) :: State.t()
  defp put_step_status(nil, state, _step_id, _status, _result), do: state

  defp put_step_status(%Step{} = step, state, step_id, status, result) do
    state
    |> State.put_step(%{step | status: status, result: result})
    |> clear_current_step_if(step_id)
  end

  @spec clear_current_step_if(State.t(), binary()) :: State.t()
  defp clear_current_step_if(%State{plan: %{current_step_id: step_id}} = state, step_id) do
    State.clear_current_step(state)
  end

  defp clear_current_step_if(state, _step_id), do: state

  @spec continue_after_resume(State.t()) :: State.t()
  defp continue_after_resume(%State{} = state) do
    state.plan
    |> Plan.current_step()
    |> continue_after_resume(state)
  end

  @spec continue_after_resume(Step.t() | nil, State.t()) :: State.t()
  defp continue_after_resume(nil, state) do
    state
    |> unblock_blocked_steps()
    |> StepGate.select_next()
  end

  defp continue_after_resume(%Step{}, state), do: state

  @spec unblock_current_step(State.t()) :: State.t()
  defp unblock_current_step(state) do
    state
    |> State.clear_current_step()
    |> unblock_blocked_steps()
  end

  @spec unblock_blocked_steps(State.t()) :: State.t()
  defp unblock_blocked_steps(state) do
    steps = Enum.map(state.plan.steps, &unblock_step/1)
    State.put_plan(state, %{state.plan | steps: steps})
  end

  @spec unblock_step(Step.t()) :: Step.t()
  defp unblock_step(%Step{status: :blocked} = step), do: %{step | status: :pending}
  defp unblock_step(%Step{} = step), do: step

  @spec approvable_step(State.t()) :: Step.t() | nil
  defp approvable_step(state) do
    Plan.current_step(state.plan) || Enum.find(state.plan.steps, &(&1.status == :blocked))
  end
end
