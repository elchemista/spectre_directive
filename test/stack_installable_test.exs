defmodule SpectreDirective.StackInstallableTest.Store do
  @moduledoc false
end

defmodule SpectreDirective.StackInstallableTest.Clock do
  @moduledoc false
end

defmodule SpectreDirective.StackInstallableTest.Stack do
  @moduledoc false

  use Spectre.Stack, id: :directive_contract_stack

  install Spectre.Directive, checkpoint: :turn_boundary do
    store(SpectreDirective.StackInstallableTest.Store)
    clock(SpectreDirective.StackInstallableTest.Clock)
    resident_runs(16)
  end
end

defmodule SpectreDirective.StackInstallableTest do
  use ExUnit.Case, async: true

  alias Spectre.Stack.Contract.V1
  alias Spectre.Stack.Definition
  alias Spectre.Stack.Installable
  alias SpectreDirective.StackInstallableTest.Clock
  alias SpectreDirective.StackInstallableTest.Stack, as: TestStack
  alias SpectreDirective.StackInstallableTest.Store

  test "publishes the versioned Directive Stack contract" do
    assert {:ok, package} = V1.verify_installable(Spectre.Directive)
    assert package.id == :directive
    assert package.version == "0.1.2"
    assert package.contract == 1
    assert package.spectre == "~> 0.1.2"
    assert package.provides == [{:service, :continuity}]
    assert package.operations == []
    assert package.actions == []
    assert package.resources == []
    assert package.dsl == Spectre.Directive
    assert is_binary(package.digest)
  end

  test "compiles continuity declarations without claiming the legacy runtime" do
    definition = Spectre.Stack.definition(TestStack)

    assert {:ok, installation} = Definition.installation(definition, :directive)

    assert installation.config == %{
             options: [checkpoint: :turn_boundary],
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
