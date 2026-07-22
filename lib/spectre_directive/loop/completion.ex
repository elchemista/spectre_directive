defmodule SpectreDirective.Loop.Completion do
  @moduledoc false

  alias SpectreDirective.Invocation
  alias SpectreDirective.Invocation.Result, as: InvocationResult
  alias SpectreDirective.Loop.State
  alias SpectreDirective.Outcome
  alias SpectreDirective.Plan
  alias SpectreDirective.Request
  alias SpectreDirective.Step

  @type begin_result :: {:complete, State.t()} | {:invoke, State.t(), Invocation.t()}

  @doc false
  @spec complete_step(State.t(), term()) :: {:ok, State.t()} | {:error, :no_current_step}
  def complete_step(%State{} = state, result) do
    case Plan.current_step(state.plan) do
      nil ->
        {:error, :no_current_step}

      %Step{} = step ->
        completed = %{step | status: :completed, result: result}

        plan =
          state.plan
          |> Plan.update_step(completed)
          |> Plan.put_current(nil)

        state =
          state
          |> Map.put(:plan, plan)
          |> Map.put(:step_invoked?, false)
          |> State.add_trace(:step_completed, "Completed step: #{step.title}", %{
            step_id: step.id,
            result: result
          })

        {:ok, state}
    end
  end

  @doc false
  @spec begin(State.t(), term()) :: begin_result()
  def begin(%State{on_complete: nil} = state, result),
    do: {:complete, complete(state, result)}

  def begin(%State{completion_started?: true} = state, result),
    do: {:complete, complete(state, result)}

  def begin(%State{} = state, result) do
    state = %{state | completion_started?: true, pending_completion_result: result}
    {:invoke, state, Invocation.new(state.on_complete)}
  end

  @doc false
  @spec finish(State.t(), Request.t(), InvocationResult.t()) :: {:ok, State.t()}
  def finish(%State{} = state, %Request{}, %InvocationResult{error: error})
      when not is_nil(error) do
    {:ok, fail(state, {:completion_invocation_failed, error})}
  end

  def finish(%State{} = state, %Request{}, %InvocationResult{} = result) do
    completion_result =
      result.mission_result || result.step_result || List.last(result.information)

    {:ok,
     state
     |> Map.put(:pending_completion_result, nil)
     |> complete(state.pending_completion_result, completion_result)}
  end

  @doc false
  @spec cancel(State.t(), term()) :: State.t()
  def cancel(%State{status: status} = state, _reason)
      when status in [:completed, :failed, :cancelled],
      do: state

  def cancel(%State{} = state, reason) do
    outcome = Outcome.new(state.mission.id, :cancelled, reason: reason)

    state
    |> Map.put(:outcome, outcome)
    |> Map.put(:pending_request, nil)
    |> State.put_status(:cancelled)
    |> State.add_trace(:cancelled, "Mission cancelled.", reason)
  end

  @doc false
  @spec fail(State.t(), term()) :: State.t()
  def fail(%State{} = state, reason) do
    outcome = Outcome.new(state.mission.id, :failed, reason: reason)

    state
    |> Map.put(:outcome, outcome)
    |> Map.put(:pending_request, nil)
    |> State.put_status(:failed)
    |> State.add_trace(:failed, "Mission failed.", reason)
  end

  @doc false
  @spec done_result(State.t()) :: {:done, Outcome.t(), State.t()}
  def done_result(%State{outcome: %Outcome{} = outcome} = state), do: {:done, outcome, state}

  @spec complete(State.t(), term(), term()) :: State.t()
  defp complete(%State{} = state, result, completion_result \\ nil) do
    outcome =
      Outcome.new(state.mission.id, :completed,
        result: result,
        completion_result: completion_result
      )

    state
    |> Map.put(:outcome, outcome)
    |> Map.put(:pending_request, nil)
    |> State.put_status(:completed)
    |> State.add_trace(:completed, "Mission completed.", outcome)
  end
end
