defmodule SpectreDirective.CapabilityProvider do
  @moduledoc """
  Capability discovery boundary for mission blueprints.

  Capabilities are not just tools. A capability is something the mission can
  realistically do in the current situation, with risk, availability, cost, and
  expected output attached.

  SpectreDirective always contributes a small base inventory such as
  `:recall_memory`, `:ask_user`, `:revise_plan`, and `:finish_early`. Host
  applications can add perception or action capabilities by passing adapter
  modules:

      defmodule MyApp.DirectiveLensAdapter do
        @behaviour SpectreDirective.CapabilityProvider

        alias SpectreDirective.Capability
        alias SpectreDirective.MissionBlueprint

        @impl SpectreDirective.CapabilityProvider
        def discover(%MissionBlueprint{}, _opts) do
          [
            Capability.new(
              name: :observe_page,
              description: "Observe a browser page through SpectreLens.",
              source: :spectre_lens,
              risk: :low
            )
          ]
        end
      end

      SpectreDirective.start_mission("Check signup",
        capability_adapters: [MyApp.DirectiveLensAdapter]
      )

  Adapter errors are treated as missing capabilities so the mission can block
  or ask instead of crashing the planner.
  """

  alias SpectreDirective.Capability
  alias SpectreDirective.MissionBlueprint

  @callback discover(MissionBlueprint.t(), keyword()) :: [Capability.t() | map()]

  @base [
    %{
      name: :recall_memory,
      description: "Recall mission memory.",
      source: :directive,
      risk: :low
    },
    %{
      name: :observe_current_state,
      description: "Observe current state before acting.",
      source: :directive,
      risk: :low
    },
    %{
      name: :ask_user,
      description: "Ask the user for missing information.",
      source: :directive,
      risk: :low
    },
    %{name: :revise_plan, description: "Revise the living plan.", source: :directive, risk: :low},
    %{
      name: :pause_mission,
      description: "Pause the mission before risk or uncertainty.",
      source: :directive,
      risk: :low
    },
    %{
      name: :finish_early,
      description: "Finish when enough evidence exists.",
      source: :directive,
      risk: :low
    }
  ]

  @doc """
  Discovers built-in, adapter-provided, and authored capabilities for a blueprint.
  """
  @spec discover(MissionBlueprint.t(), keyword()) :: [Capability.t()]
  def discover(%MissionBlueprint{} = blueprint, opts) do
    adapters = Keyword.get(opts, :capability_adapters, [])
    configured = Keyword.get(opts, :capabilities, [])

    (@base ++
       Enum.flat_map(adapters, &discover_adapter(&1, blueprint, opts)) ++
       configured_capabilities(configured) ++
       authored_capabilities(blueprint))
    |> Enum.map(&Capability.new/1)
    |> filter_denied(blueprint)
  end

  @spec discover_adapter(module(), MissionBlueprint.t(), keyword()) :: [Capability.t() | map()]
  defp discover_adapter(adapter, blueprint, opts) do
    adapter.discover(blueprint, opts)
  rescue
    _ -> []
  end

  @spec configured_capabilities([Capability.t() | map() | keyword() | atom() | binary()]) :: [
          Capability.t() | map()
        ]
  defp configured_capabilities(capabilities) when is_list(capabilities) do
    Enum.map(capabilities, &configured_capability/1)
  end

  defp configured_capabilities(_capabilities), do: []

  @spec configured_capability(Capability.t() | map() | keyword() | atom() | binary()) ::
          Capability.t() | map()
  defp configured_capability(%Capability{} = capability), do: capability

  defp configured_capability(capability) when is_atom(capability) or is_binary(capability),
    do: %{name: capability}

  defp configured_capability(capability), do: capability

  @spec authored_capabilities(MissionBlueprint.t()) :: [map()]
  defp authored_capabilities(%MissionBlueprint{capability_rules: rules}) do
    required = Map.get(rules, :required, [])
    allowed = Map.get(rules, :allowed, [])

    Enum.map(Enum.uniq(required ++ allowed), fn name ->
      %{name: name, description: "Authored directive capability.", source: :authored, risk: :low}
    end)
  end

  @spec filter_denied([Capability.t()], MissionBlueprint.t()) :: [Capability.t()]
  defp filter_denied(capabilities, %MissionBlueprint{capability_rules: rules}) do
    denied = rules |> Map.get(:denied, []) |> Enum.map(&to_string/1)
    Enum.reject(capabilities, &(to_string(&1.name) in denied))
  end
end
