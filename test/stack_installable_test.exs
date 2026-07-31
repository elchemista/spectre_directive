defmodule SpectreDirective.StackInstallableTest.Store do
  @moduledoc false
end

defmodule SpectreDirective.StackInstallableTest.Clock do
  @moduledoc false
end

defmodule SpectreDirective.StackInstallableTest.Stack do
  @moduledoc false

  use Spectre.Stack, id: :directive_contract_stack

  install Spectre.Directive, checkpoint: :turn_boundary, turn_handler: true do
    store(SpectreDirective.StackInstallableTest.Store)
    clock(SpectreDirective.StackInstallableTest.Clock)
    resident_runs(16)
  end
end

defmodule SpectreDirective.StackInstallableTest.PassiveStack do
  @moduledoc false

  use Spectre.Stack, id: :directive_passive_contract_stack

  install(Spectre.Directive)
end

defmodule SpectreDirective.StackInstallableTest.PassiveAgent do
  @moduledoc false

  use Spectre.Agent, stack: SpectreDirective.StackInstallableTest.PassiveStack
end

defmodule SpectreDirective.StackInstallableTest.Agent do
  @moduledoc false

  use Spectre.Agent, stack: SpectreDirective.StackInstallableTest.Stack

  def handle_directive({:reason, %SpectreDirective.Context{}}, _spectre_context) do
    {:blocked, :stack_reasoned}
  end
end

defmodule SpectreDirective.StackInstallableTest do
  use ExUnit.Case, async: true

  alias Spectre.Directive.StackCompiler
  alias Spectre.Stack.Contract.V1
  alias Spectre.Stack.Definition
  alias Spectre.Stack.Installable
  alias SpectreDirective.AgentDecision
  alias SpectreDirective.Context
  alias SpectreDirective.Integration.SpectreAgent
  alias SpectreDirective.StackInstallableTest.Agent
  alias SpectreDirective.StackInstallableTest.Clock
  alias SpectreDirective.StackInstallableTest.PassiveAgent
  alias SpectreDirective.StackInstallableTest.Stack, as: TestStack
  alias SpectreDirective.StackInstallableTest.Store

  test "publishes the versioned Directive Stack contract" do
    assert {:ok, package} = V1.verify_installable(Spectre.Directive)
    assert package.id == :directive
    assert package.version == "0.1.6"
    assert package.contract == 1
    assert package.spectre == "~> 0.1.5"
    assert package.provides == [{:service, :continuity}]
    assert package.operations == []
    assert package.actions == []
    assert package.resources == []
    assert package.agent_extensions == [Spectre.Directive.Extension]
    assert package.dsl == Spectre.Directive
    assert is_binary(package.digest)
  end

  test "keeps the standalone mission engine quarantined unless the handler is opted in" do
    definition = PassiveAgent.__spectre_definition__()

    assert is_map(definition.config[:directive])
    refute Keyword.has_key?(definition.config, :turn_handlers)
  end

  test "rejects ambiguous turn-handler installation values" do
    assert {:error, {:invalid_turn_handler_option, :automatic}} =
             StackCompiler.compile(
               [turn_handler: :automatic],
               nil,
               __ENV__
             )
  end

  test "selecting the Stack activates continuity and internal reasoning" do
    assert {:ok, config} = Spectre.Directive.config(Agent)
    assert config.store == Store
    assert config.clock == Clock
    assert config.resident_runs == 16

    definition = Agent.__spectre_definition__()
    assert definition.config[:directive] == config

    assert [
             {SpectreDirective.Integration.SpectreAgent.TurnHandler, handler_opts}
           ] = definition.config[:turn_handlers]

    assert handler_opts[:store] == Store
    assert handler_opts[:clock] == Clock
    assert handler_opts[:resident_runs] == 16

    context = %Context{operation: :plan}

    assert %AgentDecision{
             kind: :blocked,
             reason: :stack_reasoned
           } =
             SpectreAgent.decide(context,
               agent: Agent,
               owner: Agent
             )
  end

  test "compiles continuity declarations without claiming the legacy runtime" do
    definition = Spectre.Stack.definition(TestStack)

    assert {:ok, installation} = Definition.installation(definition, :directive)

    assert installation.config == %{
             options: [checkpoint: :turn_boundary, turn_handler: true],
             store: Store,
             clock: Clock,
             resident_runs: 16
           }

    assert installation.resources == []
    assert installation.operations == []
    assert installation.actions == []
    assert {:ok, []} = Installable.child_specs(installation, [])
    assert is_binary(installation.digest)
  end

  test "resolves continuity as a logical service and preserves the legacy facade" do
    assert {:ok, continuity_ref} =
             Spectre.Stack.resolve(TestStack, :service, :continuity)

    assert continuity_ref.package == :directive
    assert function_exported?(Spectre.Directive, :new, 1)
    assert function_exported?(Spectre.Directive, :start_link, 1)

    assert {:error, {:unknown_stack_capability, :resource, :continuity}} =
             Spectre.Stack.resolve(TestStack, :resource, :continuity)
  end
end
