defmodule SpectreDirectiveIntegrationTest do
  use ExUnit.Case

  alias Mix.Error, as: MixError
  alias Mix.Tasks.SpectreDirective.Gen.Integration
  alias SpectreDirective.CapabilityProvider
  alias SpectreDirective.MemoryStore
  alias SpectreDirective.Mission
  alias SpectreDirective.MissionBlueprint

  defmodule RecordingMemory do
    def recall(mission, opts) do
      send(opts[:parent], {:memory_recalled, mission.goal, opts[:scope]})
      {:ok, %{moments: [%{text: "remembered checkout issue"}]}}
    end

    def remember(record, opts) do
      send(opts[:parent], {:memory_recorded, record.summary, opts[:scope]})
      :ok
    end
  end

  defmodule RaisingMemory do
    def recall(_mission, _opts), do: raise("memory offline")
    def remember(_record, _opts), do: raise("memory offline")
  end

  defmodule RecordingCapabilityAdapter do
    def discover(%MissionBlueprint{} = blueprint, opts) do
      send(opts[:parent], {:capabilities_discovered, blueprint.name})

      [
        %{name: :adapter_tool, source: __MODULE__, risk: :low},
        %{name: :denied_tool, source: __MODULE__, risk: :low}
      ]
    end
  end

  defmodule RaisingCapabilityAdapter do
    def discover(%MissionBlueprint{}, _opts), do: raise("adapter unavailable")
  end

  test "memory adapters are explicit and receive caller options" do
    mission = Mission.new("Remember checkout", memory_scope: {:app, :checkout})

    assert %{moments: [%{text: "remembered checkout issue"}]} =
             MemoryStore.recall(mission,
               memory_adapter: RecordingMemory,
               memory_opts: [parent: self(), scope: {:app, :checkout}]
             )

    assert_receive {:memory_recalled, "Remember checkout", {:app, :checkout}}

    assert :ok =
             MemoryStore.remember(%{summary: "step finished"},
               memory_adapter: RecordingMemory,
               memory_opts: [parent: self(), scope: {:app, :checkout}]
             )

    assert_receive {:memory_recorded, "step finished", {:app, :checkout}}
  end

  test "missing or failing memory adapters degrade to no memory" do
    mission = Mission.new("No memory")

    assert is_nil(MemoryStore.recall(mission, []))
    assert is_nil(MemoryStore.recall(mission, memory_adapter: :none))
    assert is_nil(MemoryStore.recall(mission, memory_adapter: RaisingMemory))

    assert :ok = MemoryStore.remember(%{summary: "ignored"}, [])
    assert :ok = MemoryStore.remember(%{summary: "ignored"}, memory_adapter: :none)
    assert :ok = MemoryStore.remember(%{summary: "ignored"}, memory_adapter: RaisingMemory)
  end

  test "capability adapters merge with authored capabilities and denied rules still win" do
    blueprint =
      MissionBlueprint.new(
        name: "integration-check",
        mission: Mission.new("Check integrations"),
        capability_rules: %{
          required: [:required_tool],
          allowed: [:allowed_tool],
          denied: [:denied_tool]
        },
        steps: []
      )

    capabilities =
      CapabilityProvider.discover(blueprint,
        capability_adapters: [RecordingCapabilityAdapter, RaisingCapabilityAdapter],
        parent: self()
      )

    names = Enum.map(capabilities, & &1.name)

    assert_receive {:capabilities_discovered, "integration-check"}
    assert :recall_memory in names
    assert :required_tool in names
    assert :allowed_tool in names
    assert :adapter_tool in names
    refute :denied_tool in names
  end

  test "generated Spectre integration adapters target host application modules" do
    tmp_dir =
      Path.join(System.tmp_dir!(), "spectre_directive_integration_#{System.unique_integer()}")

    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.cd!(tmp_dir, fn ->
      Integration.run([
        "--app",
        "demo_app",
        "--only",
        "mnemonic,kinetic,lens"
      ])
    end)

    mnemonic = Path.join(tmp_dir, "lib/demo_app/spectre_directive/mnemonic_adapter.ex")
    kinetic = Path.join(tmp_dir, "lib/demo_app/spectre_directive/kinetic_adapter.ex")
    lens = Path.join(tmp_dir, "lib/demo_app/spectre_directive/lens_adapter.ex")

    assert File.read!(mnemonic) =~ "defmodule DemoApp.SpectreDirective.MnemonicAdapter"
    assert File.read!(mnemonic) =~ "@behaviour SpectreDirective.MemoryStore"
    assert File.read!(kinetic) =~ "@behaviour SpectreDirective.CapabilityProvider"
    assert File.read!(kinetic) =~ "%MissionBlueprint{}"
    assert File.read!(lens) =~ "SpectreLens.look"
    assert File.read!(lens) =~ "%MissionBlueprint{}"
  end

  test "integration generator rejects unknown integration names" do
    assert_raise MixError, ~r/unknown SpectreDirective integration/, fn ->
      Integration.run(["--only", "mnemonic,unknown"])
    end
  end
end
