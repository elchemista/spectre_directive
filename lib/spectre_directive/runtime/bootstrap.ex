defmodule SpectreDirective.Runtime.Bootstrap do
  @moduledoc """
  Builds the initial runtime state for a mission blueprint.

  This module is the boundary between the runtime process and external
  adapter discovery. The runtime loop receives normalized domain state.
  """

  alias SpectreDirective.CapabilityProvider
  alias SpectreDirective.CapabilitySnapshot
  alias SpectreDirective.Knowledge
  alias SpectreDirective.MemoryStore
  alias SpectreDirective.MissionBlueprint
  alias SpectreDirective.Plan
  alias SpectreDirective.Planner
  alias SpectreDirective.Planning.Session
  alias SpectreDirective.Runtime.State

  @doc """
  Creates initial state with recalled knowledge and discovered capabilities.
  """
  @spec build(MissionBlueprint.t(), keyword()) :: State.t()
  def build(%MissionBlueprint{} = blueprint, opts) when is_list(opts) do
    knowledge =
      blueprint.mission
      |> Knowledge.new()
      |> Knowledge.merge_recall(MemoryStore.recall(blueprint.mission, opts))

    capabilities = CapabilitySnapshot.new(CapabilityProvider.discover(blueprint, opts))

    case planning_mode(opts) do
      :guided ->
        %State{
          blueprint: put_in(blueprint.mission.status, :planning),
          knowledge: knowledge,
          capabilities: capabilities,
          plan: Plan.new([], source: :agent_generated, reason: "Manual guided planning pending."),
          planning: Session.new(blueprint.plan),
          status: :planning,
          opts: opts
        }
        |> State.add_trace(:planning_started, "Started manual guided planning.")

      _mode ->
        planning = Planner.build_initial_plan(blueprint, knowledge, capabilities, opts)

        state = %State{
          blueprint: put_in(blueprint.mission.status, :running),
          knowledge: knowledge,
          capabilities: capabilities,
          plan: planning.plan,
          status: :running,
          opts: opts
        }

        Enum.reduce(planning.trace, state, fn {type, message, data}, acc ->
          State.add_trace(acc, type, message, data)
        end)
    end
  end

  @spec planning_mode(keyword()) :: atom()
  defp planning_mode(opts), do: Keyword.get(opts, :planning_mode, :draft)
end
