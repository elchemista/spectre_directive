defmodule SpectreDirective.Alignment do
  @moduledoc """
  Built-in mission-alignment checks.
  """

  alias SpectreDirective.Alignment.Result
  alias SpectreDirective.CapabilitySnapshot
  alias SpectreDirective.Plan
  alias SpectreDirective.Step

  @checks [
    :mission_relevance,
    :context_relevance,
    :information_value,
    :confidence,
    :cost,
    :risk,
    :capability,
    :drift,
    :redundancy
  ]

  @doc """
  Returns the built-in alignment check names.
  """
  @spec checks() :: [atom()]
  def checks, do: @checks

  @doc """
  Checks whether a step still serves the mission.
  """
  @spec check(map(), Step.t() | nil, :pre_step | :post_step) :: Result.t()
  def check(_state, nil, phase) do
    Result.new(
      status: :complete_enough,
      recommendation: :finish,
      phase: phase,
      check: :confidence,
      reason: "No useful pending step remains."
    )
  end

  def check(state, %Step{} = step, phase) do
    cond do
      complete_enough?(state) ->
        Result.new(
          status: :complete_enough,
          recommendation: :finish,
          phase: phase,
          check: :confidence,
          reason: "Current knowledge is enough to finish the mission."
        )

      risky_without_approval?(state, step) ->
        Result.new(
          status: :risky,
          recommendation: :pause,
          phase: phase,
          check: :risk,
          reason: "The step carries high risk or requires approval."
        )

      missing_capability?(state, step) ->
        Result.new(
          status: :blocked,
          recommendation: :ask,
          phase: phase,
          check: :capability,
          reason: "The required capability is not available now."
        )

      mission_drift?(state, step) ->
        Result.new(
          status: :misaligned,
          recommendation: :skip,
          phase: phase,
          check: :drift,
          reason: "The step appears to chase evidence that is low-value for the mission context."
        )

      redundant?(state, step) ->
        Result.new(
          status: :weakly_aligned,
          recommendation: :skip,
          phase: phase,
          check: :redundancy,
          reason: "The step appears redundant with completed work."
        )

      true ->
        Result.new(
          status: :aligned,
          recommendation: :continue,
          phase: phase,
          check: :mission_relevance,
          score: 1.0,
          reason: "The step still appears useful for the mission."
        )
    end
  end

  @spec complete_enough?(map()) :: boolean()
  defp complete_enough?(%{status: status}) when status in [:finished, :stopped, :aborted],
    do: true

  defp complete_enough?(%{knowledge: %{decisions: decisions}}) do
    Enum.any?(decisions, &String.contains?(String.downcase(to_string(&1)), "finish early"))
  end

  defp complete_enough?(_state), do: false

  @spec risky_without_approval?(map(), Step.t()) :: boolean()
  defp risky_without_approval?(%{approvals: approvals}, %Step{} = step) do
    step.risk in [:high, :critical] and not MapSet.member?(approvals, step.id)
  end

  defp risky_without_approval?(_state, %Step{} = step), do: step.risk in [:high, :critical]

  @spec missing_capability?(map(), Step.t()) :: boolean()
  defp missing_capability?(_state, %Step{required_capability: nil}), do: false

  defp missing_capability?(%{capabilities: %CapabilitySnapshot{} = snapshot}, %Step{} = step) do
    is_nil(CapabilitySnapshot.find(snapshot, step.required_capability))
  end

  defp missing_capability?(_state, _step), do: false

  @spec mission_drift?(map(), Step.t()) :: boolean()
  defp mission_drift?(%{blueprint: %{mission: mission}}, %Step{} = step) do
    context = downcase_join([mission.goal, mission.context, mission.success_criteria])
    step_text = downcase_join([step.title, step.purpose, step.reason, step.prompt])

    String.contains?(context, "react") and
      String.contains?(context, "frontend") and
      String.contains?(step_text, "backend") and
      not String.contains?(step_text, "frontend")
  end

  defp mission_drift?(_state, _step), do: false

  @spec redundant?(map(), Step.t()) :: boolean()
  defp redundant?(%{plan: %Plan{} = plan}, %Step{} = step) do
    completed_text =
      plan.completed_steps
      |> Enum.map_join("\n", &downcase_join([&1.title, &1.purpose]))

    needle = downcase_join([step.title, step.purpose])
    needle != "" and String.contains?(completed_text, needle)
  end

  defp redundant?(_state, _step), do: false

  @spec downcase_join([term()]) :: binary()
  defp downcase_join(values) do
    values
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" ", &to_string/1)
    |> String.downcase()
  end
end
