defmodule SpectreDirective.Pulse do
  @moduledoc "A compact, read-only view of a live mission loop."

  alias SpectreDirective.Loop.State
  alias SpectreDirective.Plan

  @type t :: %__MODULE__{
          mission_id: binary(),
          mission: binary(),
          status: atom(),
          current_step: SpectreDirective.Step.t() | nil,
          pending_request: SpectreDirective.Request.t() | nil,
          plan_version: pos_integer(),
          iteration: non_neg_integer(),
          information_count: non_neg_integer(),
          outcome: SpectreDirective.Outcome.t() | nil,
          controls: [atom()],
          updated_at: DateTime.t()
        }

  defstruct [
    :mission_id,
    :mission,
    :status,
    :current_step,
    :pending_request,
    :plan_version,
    :outcome,
    iteration: 0,
    information_count: 0,
    controls: [],
    updated_at: nil
  ]

  @doc "Builds a pulse from pure loop state."
  @spec from_loop(State.t()) :: t()
  def from_loop(%State{} = state) do
    %__MODULE__{
      mission_id: state.mission.id,
      mission: state.mission.goal,
      status: state.status,
      current_step: Plan.current_step(state.plan),
      pending_request: state.pending_request,
      plan_version: state.plan.version,
      iteration: state.iteration,
      information_count: length(state.working_context.information),
      outcome: state.outcome,
      controls: controls(state.status),
      updated_at: DateTime.utc_now()
    }
  end

  @spec controls(atom()) :: [atom()]
  defp controls(status) when status in [:completed, :failed, :cancelled], do: []
  defp controls(:paused), do: [:resume, :cancel, :inform]
  defp controls(_status), do: [:respond, :inform, :pause, :cancel]
end
