defmodule SpectreDirective.Invocation.Result do
  @moduledoc """
  Normalized transition requested by an application invocation.

  Invocation functions may return convenient tuples such as
  `{:complete_step, value}`. `normalize/1` converts each supported form into
  this explicit structure before the pure engine changes mission state.
  """

  alias SpectreDirective.PlanPatch

  @type transition :: :reason | :complete_step | :complete_mission | :propose_patch | :ask

  @type t :: %__MODULE__{
          information: [term()],
          transition: transition(),
          step_result: term(),
          mission_result: term(),
          plan_patch: PlanPatch.t() | term(),
          question: term(),
          error: term(),
          metadata: map()
        }

  defstruct information: [],
            transition: :reason,
            step_result: nil,
            mission_result: nil,
            plan_patch: nil,
            question: nil,
            error: nil,
            metadata: %{}

  @doc "Normalizes a supported invocation return value."
  @spec normalize(term()) :: {:ok, t()}
  def normalize(%__MODULE__{} = result), do: {:ok, result}
  def normalize({:ok, value}), do: normalize({:inform, value})
  def normalize(:ok), do: normalize({:inform, :ok})

  def normalize({:inform, value}) do
    {:ok, %__MODULE__{information: values(value), transition: :reason}}
  end

  def normalize({:complete_step, value}) do
    {:ok,
     %__MODULE__{
       information: values(value),
       transition: :complete_step,
       step_result: value
     }}
  end

  def normalize({:complete_mission, value}) do
    {:ok,
     %__MODULE__{
       information: values(value),
       transition: :complete_mission,
       mission_result: value
     }}
  end

  def normalize({:propose_patch, patch, information}) do
    {:ok,
     %__MODULE__{
       information: values(information),
       transition: :propose_patch,
       plan_patch: patch
     }}
  end

  def normalize({:ask, question}) do
    {:ok, %__MODULE__{transition: :ask, question: question}}
  end

  def normalize({:error, reason}) do
    {:ok,
     %__MODULE__{
       information: [%{error: reason}],
       transition: :reason,
       error: reason
     }}
  end

  def normalize(value), do: normalize({:inform, value})

  @spec values(term()) :: [term()]
  defp values(nil), do: []
  defp values(value), do: [value]
end
