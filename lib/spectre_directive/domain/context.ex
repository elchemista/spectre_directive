defmodule SpectreDirective.Context do
  @moduledoc """
  Read-only loop snapshot passed to reasoners and invocation functions.

  Returning a decision or invocation result is how external code requests a
  state transition. The snapshot itself is never mutated by the callback.
  """

  alias SpectreDirective.Information
  alias SpectreDirective.Mission
  alias SpectreDirective.Plan
  alias SpectreDirective.Step

  @type t :: %__MODULE__{
          mission: Mission.t(),
          plan: Plan.t(),
          mode: atom(),
          plan_status: atom(),
          step: Step.t() | nil,
          information: [Information.t()],
          last_result: term(),
          input: term(),
          assigns: map(),
          revision: non_neg_integer(),
          iteration: non_neg_integer(),
          operation: atom() | nil
        }

  defstruct [
    :mission,
    :plan,
    :mode,
    :plan_status,
    :step,
    :last_result,
    :input,
    :operation,
    information: [],
    assigns: %{},
    revision: 0,
    iteration: 0
  ]

  @doc "Returns a model-friendly projection without executable callback targets."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = context) do
    %{
      mission: %{
        id: context.mission.id,
        goal: context.mission.goal,
        context: context.mission.context,
        success_criteria: context.mission.success_criteria,
        constraints: context.mission.constraints,
        risk_boundaries: context.mission.risk_boundaries,
        status: context.mission.status,
        metadata: context.mission.metadata
      },
      plan: %{
        id: context.plan.id,
        version: context.plan.version,
        reason: context.plan.reason,
        source: context.plan.source,
        current_step_id: context.plan.current_step_id,
        steps: Enum.map(context.plan.steps, &step_to_map/1),
        revision_history:
          Enum.map(context.plan.revision_history, &Map.take(&1, [:version, :reason, :timestamp]))
      },
      mode: context.mode,
      plan_status: context.plan_status,
      step: context.step && step_to_map(context.step),
      information: Enum.map(context.information, &information_to_map/1),
      last_result: context.last_result,
      input: context.input,
      assigns: context.assigns,
      revision: context.revision,
      iteration: context.iteration,
      operation: context.operation
    }
  end

  @spec step_to_map(Step.t()) :: map()
  defp step_to_map(%Step{} = step) do
    step
    |> Map.from_struct()
    |> Map.drop([:invoke])
    |> Map.put(:invokable?, not is_nil(step.invoke))
  end

  @spec information_to_map(Information.t()) :: map()
  defp information_to_map(%Information{} = information), do: Map.from_struct(information)
end
