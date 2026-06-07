defmodule SpectreDirective.Pulse do
  @moduledoc """
  Live status snapshot for a mission.

  A pulse is the compact "what is happening now?" view:

  * mission and context,
  * current step,
  * current understanding,
  * alignment and risk,
  * blocked status,
  * next expected action,
  * available controls.

  It is intentionally more meaningful than a step counter. Agents and humans
  need to know whether the mission is aligned, blocked, risky, or complete
  enough, not only that "step 3 is running."
  """

  alias SpectreDirective.Plan

  @type t :: %__MODULE__{
          mission_id: binary(),
          mission: binary(),
          context: binary() | nil,
          status: atom(),
          current_step: term(),
          current_understanding: binary(),
          alignment: term(),
          risk: atom(),
          blocked?: boolean(),
          next_expected_action: binary() | nil,
          controls: [atom()],
          updated_at: DateTime.t()
        }

  defstruct [
    :mission_id,
    :mission,
    :context,
    :status,
    :current_step,
    :current_understanding,
    :alignment,
    :risk,
    :next_expected_action,
    blocked?: false,
    controls: [],
    updated_at: nil
  ]

  @doc """
  Builds a live mission pulse from runtime state.
  """
  @spec from_state(map()) :: t()
  def from_state(%{blueprint: blueprint, plan: %Plan{} = plan} = state) do
    current = Plan.current_step(plan)
    alignment = Map.get(state, :last_alignment)

    %__MODULE__{
      mission_id: blueprint.mission.id,
      mission: blueprint.mission.goal,
      context: blueprint.mission.context,
      status: Map.get(state, :status, blueprint.mission.status),
      current_step: current,
      current_understanding: understanding(Map.get(state, :knowledge)),
      alignment: alignment,
      risk: current_risk(current, Map.get(state, :capabilities)),
      blocked?: Map.get(state, :status) in [:blocked, :waiting],
      next_expected_action: next_action(current, alignment),
      controls: controls(Map.get(state, :status)),
      updated_at: DateTime.utc_now()
    }
  end

  @spec understanding(term()) :: binary()
  defp understanding(nil), do: "No mission knowledge has been recorded yet."

  defp understanding(knowledge) do
    facts =
      (knowledge.mission_relevant_facts ++ knowledge.derived_facts ++ knowledge.known_facts)
      |> Enum.reject(&is_nil/1)
      |> Enum.take(-3)

    case facts do
      [] -> "No mission-relevant facts have been recorded yet."
      facts -> Enum.map_join(facts, "\n", &to_string/1)
    end
  end

  @spec current_risk(term(), term()) :: atom()
  defp current_risk(nil, _capabilities), do: :low
  defp current_risk(step, _capabilities), do: step.risk

  @spec next_action(term(), term()) :: binary()
  defp next_action(nil, _alignment), do: "Finish or wait for a revised plan."

  defp next_action(step, %{recommendation: recommendation}) do
    "#{recommendation}: #{step.title}"
  end

  defp next_action(step, _alignment), do: step.title

  @spec controls(atom()) :: [atom()]
  defp controls(status) when status in [:finished, :stopped, :aborted], do: []
  defp controls(:paused), do: [:resume, :stop, :revise, :finish_early]
  defp controls(:waiting), do: [:approve, :reject, :revise, :stop]
  defp controls(_status), do: [:pause, :stop, :retry, :skip, :revise, :finish_early]
end
