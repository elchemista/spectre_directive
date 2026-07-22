defmodule SpectreDirective.Loop.PlanReducer do
  @moduledoc false

  alias SpectreDirective.Loop.State
  alias SpectreDirective.Plan
  alias SpectreDirective.PlanPatch

  @type proposal_type :: :plan | :patch
  @type change_result :: {:ok, State.t()} | {:confirm, State.t()} | {:error, term()}
  @type confirmation :: {:accept, term()} | {:reject, term()} | {:error, term()}

  @doc false
  @spec normalize_proposed(State.t(), term()) :: {:ok, Plan.t()} | {:error, term()}
  def normalize_proposed(%State{} = state, proposed) do
    if Enum.any?(state.plan.steps, &(&1.status in [:running, :completed])) do
      {:error, :plan_already_started_use_patch}
    else
      normalize_unstarted_plan(proposed)
    end
  end

  @doc false
  @spec apply_confirmed(State.t(), proposal_type(), term()) ::
          {:ok, State.t()} | {:error, term()}
  def apply_confirmed(state, :plan, plan) do
    with {:ok, normalized} <- normalize_proposed(state, plan),
         {:ok, state} <- apply_plan(state, normalized) do
      {:ok, State.add_trace(state, :proposal_accepted, "Accepted generated plan.")}
    end
  end

  def apply_confirmed(state, :patch, patch) do
    patch = with_version(patch, state.plan.version)

    with {:ok, state} <- apply_patch(state, patch) do
      {:ok, State.add_trace(state, :proposal_accepted, "Accepted generated plan patch.")}
    end
  end

  @doc false
  @spec apply_change(State.t(), proposal_type(), Plan.t() | PlanPatch.t()) :: change_result()
  def apply_change(%State{mode: :fixed}, type, _proposal),
    do: {:error, {:plan_change_not_allowed, type}}

  def apply_change(%State{mode: :guided} = state, _type, _proposal), do: {:confirm, state}

  def apply_change(%State{mode: :autonomous} = state, :plan, %Plan{} = plan),
    do: apply_plan(state, plan)

  def apply_change(%State{mode: :autonomous} = state, :patch, %PlanPatch{} = patch),
    do: apply_patch(state, patch)

  @doc false
  @spec with_version(term(), pos_integer()) :: PlanPatch.t()
  def with_version(patch, version) do
    patch = PlanPatch.new(patch)
    if is_nil(patch.base_version), do: %{patch | base_version: version}, else: patch
  end

  @doc false
  @spec confirmation(term(), term()) :: confirmation()
  def confirmation(response, proposal) when response in [:accept, :approved, true],
    do: {:accept, proposal}

  def confirmation({:ok, response}, proposal), do: confirmation(response, proposal)
  def confirmation({:accept, edited}, _proposal), do: {:accept, edited}
  def confirmation({:edit, edited}, _proposal), do: {:accept, edited}
  def confirmation({:reject, reason}, _proposal), do: {:reject, reason}

  def confirmation(response, _proposal) when response in [:reject, false],
    do: {:reject, :rejected}

  def confirmation(response, _proposal), do: {:error, {:invalid_confirmation, response}}

  @spec normalize_unstarted_plan(term()) :: {:ok, Plan.t()} | {:error, term()}
  defp normalize_unstarted_plan(proposed) do
    with {:ok, plan} <- build_plan(proposed) do
      steps = Enum.map(plan.steps, &%{&1 | status: :pending, source: :generated})
      {:ok, %{plan | steps: steps, current_step_id: nil, source: :agent_generated}}
    end
  end

  @spec build_plan(term()) :: {:ok, Plan.t()} | {:error, term()}
  defp build_plan(%Plan{} = plan), do: {:ok, plan}
  defp build_plan(%{steps: steps}), do: new_plan(steps)
  defp build_plan(%{"steps" => steps}), do: new_plan(steps)
  defp build_plan(steps) when is_list(steps), do: new_plan(steps)
  defp build_plan(other), do: {:error, {:invalid_proposed_plan, other}}

  @spec new_plan(term()) :: {:ok, Plan.t()} | {:error, term()}
  defp new_plan(steps) do
    {:ok, Plan.new(steps, source: :agent_generated)}
  rescue
    error -> {:error, {:invalid_proposed_plan, error}}
  end

  @spec apply_plan(State.t(), Plan.t()) :: {:ok, State.t()}
  defp apply_plan(%State{} = state, %Plan{} = proposed) do
    revision = %{
      version: state.plan.version + 1,
      reason: "Accepted generated plan.",
      timestamp: DateTime.utc_now()
    }

    plan = %{
      proposed
      | version: state.plan.version + 1,
        revision_history: state.plan.revision_history ++ [revision],
        current_step_id: nil
    }

    state =
      state
      |> Map.put(:plan, plan)
      |> Map.put(:plan_confirmed?, true)
      |> Map.put(:step_invoked?, false)
      |> State.add_trace(:planned, "Applied generated mission plan.", %{
        plan_version: plan.version,
        steps: Enum.map(plan.steps, & &1.title)
      })

    {:ok, state}
  end

  @spec apply_patch(State.t(), PlanPatch.t()) :: {:ok, State.t()} | {:error, term()}
  defp apply_patch(%State{} = state, %PlanPatch{} = patch) do
    with {:ok, plan} <- PlanPatch.apply(state.plan, patch) do
      {:ok,
       state
       |> Map.put(:plan, plan)
       |> maybe_reset_step_invocation(plan)
       |> State.add_trace(:plan_patched, "Applied plan patch.", patch)}
    end
  end

  @spec maybe_reset_step_invocation(State.t(), Plan.t()) :: State.t()
  defp maybe_reset_step_invocation(%State{} = state, %Plan{} = plan) do
    if Plan.current_step(plan), do: state, else: %{state | step_invoked?: false}
  end
end
