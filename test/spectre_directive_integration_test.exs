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

  defmodule RuntimeMemory do
    def recall(mission, opts) do
      send(opts[:parent], {:runtime_memory_recalled, mission.goal, mission.memory_scope})
      {:ok, %{moments: [%{text: "previous signup run blocked on verification"}]}}
    end

    def remember(record, opts) do
      send(
        opts[:parent],
        {:runtime_memory_recorded, record.mission_id, record.observation.summary}
      )

      :ok
    end
  end

  defmodule RuntimeCapabilityAdapter do
    def discover(%MissionBlueprint{} = blueprint, opts) do
      send(
        opts[:parent],
        {:runtime_capability_discovered, blueprint.name, blueprint.strategies,
         blueprint.capability_rules}
      )

      [
        %{name: :observe_page, source: __MODULE__, risk: :low},
        %{name: :fill_test_form, source: __MODULE__, risk: :medium},
        %{name: :real_payment, source: __MODULE__, risk: :critical}
      ]
    end
  end

  defmodule SignupRuntimeDirective do
    use SpectreDirective

    directive "signup-runtime" do
      mission("Check signup through integration seams.")
      context("Release QA. Use test data only.")
      success("A signup blocker or success state is reported.")
      mode(:guided)

      memory do
        scope({:app, :signup})
        remember(:observations)
      end

      capabilities do
        require_capability(:observe_page)
        allow(:fill_test_form)
        deny(:real_payment)
      end

      strategies do
        strategy(:qa_flow)
        strategy(:safe_operator)
      end

      step "Fallback authored observation" do
        kind(:observe)
        capability(:observe_page)
        purpose("Fallback if guided planning finishes without accepted steps.")
      end
    end
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

  test "manual guided mission integrates memory, capabilities, subscribers, planning, and remember" do
    parent = self()

    model = fn request, opts ->
      send(
        parent,
        {:runtime_planner_called, request.mode, opts[:parent] == parent, request.prompt}
      )

      case request.mode do
        :guided_strategy ->
          "Strategy: observe signup state with remembered blocker context."

        :guided_step ->
          """
          Step: Observe signup with integration adapter
          kind: observe
          purpose: Inspect signup with adapter-discovered capabilities and recalled memory.
          capability: observe_page
          done: Signup state is known.
          """
      end
    end

    assert {:ok, pid} =
             SpectreDirective.start_directive(SignupRuntimeDirective,
               planning_mode: :guided,
               planning_model: model,
               memory_adapter: RuntimeMemory,
               memory_opts: [parent: parent],
               capability_adapters: [RuntimeCapabilityAdapter],
               planning_subscribers: [parent],
               parent: parent
             )

    assert_receive {:runtime_memory_recalled, "Check signup through integration seams.",
                    {:app, :signup}}

    assert_receive {:runtime_capability_discovered, "signup-runtime", [:qa_flow, :safe_operator],
                    rules}

    assert rules.required == [:observe_page]
    assert rules.allowed == [:fill_test_form]
    assert rules.denied == [:real_payment]

    assert {:ok, pulse} = SpectreDirective.pulse(pid)
    assert pulse.status == :planning
    assert {:error, :planning_in_progress} = SpectreDirective.next_step(pid)

    assert {:ok, strategy} = SpectreDirective.propose_plan_item(pid)
    assert strategy.type == :strategy

    assert_receive {:runtime_planner_called, :guided_strategy, true, strategy_prompt}
    assert strategy_prompt =~ "previous signup run blocked on verification"
    assert strategy_prompt =~ "observe_page"
    assert strategy_prompt =~ "fill_test_form"
    refute strategy_prompt =~ "real_payment"
    assert strategy_prompt =~ "qa_flow"
    assert strategy_prompt =~ "pause_before_impact"
    assert_receive {:spectre_directive, _mission_id, :planning_proposal, ^strategy}

    assert {:ok, planning} = SpectreDirective.accept_plan_item(pid)
    assert planning.strategy =~ "remembered blocker context"

    assert {:ok, step_proposal} = SpectreDirective.propose_plan_item(pid)

    assert_receive {:runtime_planner_called, :guided_step, true, step_prompt}
    assert step_prompt =~ "remembered blocker context"
    assert step_prompt =~ "Steps already generated:\n-"

    assert step_proposal.type == :step
    assert step_proposal.step.required_capability == "observe_page"
    assert {:ok, planning} = SpectreDirective.accept_plan_item(pid)
    assert Enum.map(planning.steps, & &1.title) == ["Observe signup with integration adapter"]

    assert {:ok, running} = SpectreDirective.finish_planning(pid)
    assert running.status == :running
    assert running.current_step.title == "Observe signup with integration adapter"

    assert {:ok, finished} =
             SpectreDirective.complete_step(pid, %{
               summary: "Signup page is visible and waits for email verification.",
               mission_relevant_facts: ["Signup is blocked by email verification."],
               decisions: ["finish early because signup state is known"],
               correction: %{
                 type: :finish_early,
                 strategy: :confidence,
                 reason: "The integration runner has enough evidence."
               }
             })

    assert finished.status == :finished

    assert_receive {:runtime_memory_recorded, mission_id,
                    "Signup page is visible and waits for email verification."}

    assert is_binary(mission_id)
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

  test "integration generator can emit only selected adapters" do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "spectre_directive_integration_only_#{System.unique_integer()}"
      )

    File.rm_rf!(tmp_dir)
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.cd!(tmp_dir, fn ->
      Integration.run([
        "--app",
        "demo_app",
        "--only",
        "lens"
      ])
    end)

    base = Path.join(tmp_dir, "lib/demo_app/spectre_directive")

    assert File.exists?(Path.join(base, "lens_adapter.ex"))
    refute File.exists?(Path.join(base, "mnemonic_adapter.ex"))
    refute File.exists?(Path.join(base, "kinetic_adapter.ex"))
  end

  test "integration generator rejects unknown integration names" do
    assert_raise MixError, ~r/unknown SpectreDirective integration/, fn ->
      Integration.run(["--only", "mnemonic,unknown"])
    end
  end
end
