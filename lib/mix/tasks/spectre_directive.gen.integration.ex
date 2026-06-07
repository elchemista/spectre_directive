defmodule Mix.Tasks.SpectreDirective.Gen.Integration do
  @moduledoc """
  Generates host-application adapters for SpectreDirective integrations.

  The generated adapters live in the host app namespace and can depend on
  SpectreMnemonic, SpectreKinetic, or SpectreLens without making this library
  depend on those packages.

      mix spectre_directive.gen.integration
      mix spectre_directive.gen.integration --only mnemonic,lens
      mix spectre_directive.gen.integration --app my_app
  """

  use Mix.Task

  @shortdoc "Generates SpectreDirective adapter modules"

  @integrations ["mnemonic", "kinetic", "lens"]

  @impl Mix.Task
  @spec run([binary()]) :: :ok
  def run(args) do
    {opts, _argv, _invalid} = OptionParser.parse(args, strict: [app: :string, only: :string])
    app = Keyword.get(opts, :app) || Atom.to_string(Mix.Project.config()[:app])
    module_prefix = Macro.camelize(app)

    opts
    |> selected_integrations()
    |> Enum.each(&write_integration(&1, app, module_prefix))
  end

  @spec selected_integrations(keyword()) :: [binary()]
  defp selected_integrations(opts) do
    selected =
      opts
      |> Keyword.get(:only, Enum.join(@integrations, ","))
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    unknown = selected -- @integrations

    if unknown == [] do
      selected
    else
      Mix.raise("unknown SpectreDirective integration(s): #{Enum.join(unknown, ", ")}")
    end
  end

  @spec write_integration(binary(), binary(), binary()) :: :ok
  defp write_integration(integration, app, module_prefix) do
    path = Path.join(["lib", app, "spectre_directive", "#{integration}_adapter.ex"])

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, template(integration, module_prefix))
    Mix.shell().info("* creating #{path}")
  end

  @spec template(binary(), binary()) :: binary()
  defp template("mnemonic", module_prefix) do
    """
    defmodule #{module_prefix}.SpectreDirective.MnemonicAdapter do
      @moduledoc \"\"\"
      SpectreDirective memory adapter backed by SpectreMnemonic.
      \"\"\"

      @behaviour SpectreDirective.MemoryStore

      alias SpectreDirective.Mission

      @impl SpectreDirective.MemoryStore
      @spec recall(Mission.t(), keyword()) :: {:ok, term()} | {:error, term()}
      def recall(%Mission{} = mission, opts) do
        SpectreMnemonic.recall(
          recall_cue(mission),
          Keyword.put_new(opts, :scope, mission.memory_scope)
        )
      end

      @impl SpectreDirective.MemoryStore
      @spec remember(term(), keyword()) :: :ok | {:ok, term()} | {:error, term()}
      def remember(record, opts) do
        _ = SpectreMnemonic.signal(record, signal_opts(record, opts))
        SpectreMnemonic.remember(record, remember_opts(record, opts))
      end

      @spec recall_cue(Mission.t()) :: binary()
      defp recall_cue(mission) do
        [
          mission.goal,
          mission.context,
          mission.success_criteria,
          "prior decisions observations corrections known failures preferences"
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\\n")
      end

      @spec signal_opts(map(), keyword()) :: keyword()
      defp signal_opts(record, opts) do
        [
          stream: :spectre_directive,
          task_id: Map.get(record, :mission_id),
          kind: :directive_step,
          metadata: %{mission: Map.get(record, :mission)}
        ]
        |> Keyword.merge(Keyword.take(opts, [:actor, :tags]))
      end

      @spec remember_opts(map(), keyword()) :: keyword()
      defp remember_opts(record, opts) do
        [
          kind: :directive_step,
          task_id: Map.get(record, :mission_id),
          tags: [:spectre_directive]
        ]
        |> Keyword.merge(Keyword.take(opts, [:actor, :persist?, :extract_entities?]))
      end
    end
    """
  end

  defp template("kinetic", module_prefix) do
    """
    defmodule #{module_prefix}.SpectreDirective.KineticAdapter do
      @moduledoc \"\"\"
      SpectreDirective capability adapter backed by SpectreKinetic.
      \"\"\"

      @behaviour SpectreDirective.CapabilityProvider

      alias SpectreDirective.Capability
      alias SpectreDirective.MissionBlueprint

      @impl SpectreDirective.CapabilityProvider
      @spec discover(MissionBlueprint.t(), keyword()) :: [Capability.t()]
      def discover(%MissionBlueprint{} = _blueprint, opts) do
        case Keyword.get(opts, :kinetic) do
          nil ->
            []

          target ->
            [
              Capability.new(
                name: :plan_action,
                description: "Plan an action through SpectreKinetic.",
                source: :spectre_kinetic,
                risk: :low,
                metadata: %{target: target}
              )
            ]
        end
      end

      @doc \"\"\"
      Plans one Action Language instruction through SpectreKinetic.
      \"\"\"
      @spec plan(term(), binary(), keyword()) :: {:ok, term()} | {:error, term()}
      def plan(target, al, opts \\\\ []) when is_binary(al) do
        SpectreKinetic.plan(target, al, opts)
      end
    end
    """
  end

  defp template("lens", module_prefix) do
    """
    defmodule #{module_prefix}.SpectreDirective.LensAdapter do
      @moduledoc \"\"\"
      SpectreDirective capability adapter backed by SpectreLens.
      \"\"\"

      @behaviour SpectreDirective.CapabilityProvider

      alias SpectreDirective.Capability
      alias SpectreDirective.MissionBlueprint

      @impl SpectreDirective.CapabilityProvider
      @spec discover(MissionBlueprint.t(), keyword()) :: [Capability.t()]
      def discover(%MissionBlueprint{} = _blueprint, _opts) do
        [
          Capability.new(
            name: :observe_page,
            description: "Observe a browser page through SpectreLens.",
            source: :spectre_lens,
            risk: :low
          ),
          Capability.new(
            name: :act_on_page,
            description: "Perform a browser action through SpectreLens.",
            source: :spectre_lens,
            risk: :medium
          ),
          Capability.new(
            name: :discover_site,
            description: "Discover a goal-scoped navigation frontier.",
            source: :spectre_lens,
            risk: :low
          )
        ]
      end

      @doc \"\"\"
      Observes a Lens tab.
      \"\"\"
      @spec observe(term(), keyword()) :: {:ok, term()} | {:error, term()}
      def observe(tab, opts \\\\ []) do
        SpectreLens.look(tab, opts)
      end

      @doc \"\"\"
      Performs one Lens action.
      \"\"\"
      @spec act(term(), term(), keyword()) :: :ok | {:ok, term()} | {:error, term()}
      def act(tab, action, opts \\\\ []) do
        SpectreLens.act(tab, action, opts)
      end
    end
    """
  end
end
