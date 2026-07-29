defmodule SpectreDirective.RunConformanceTest.Stack do
  @moduledoc false

  use Spectre.Stack, id: :directive_run_conformance

  install(Spectre.Directive)
end

defmodule SpectreDirective.RunConformanceTest.Agent do
  @moduledoc false

  use Spectre.Agent, stack: SpectreDirective.RunConformanceTest.Stack
end

defmodule SpectreDirective.RunConformanceTest do
  use ExUnit.Case, async: true

  alias Spectre.Run
  alias Spectre.Runtime
  alias SpectreDirective.RunConformanceTest.Agent

  test "the passive installation checkpoints only the core Run continuation" do
    assert {:continue, run} =
             Runtime.start(Agent, "no implicit mission executor",
               conversation_id: "directive-passive"
             )

    assert run.waiting == nil
    assert run.metadata == %{}
    refute Map.has_key?(run.state.data, :directive)

    assert {:ok, checkpoint} = Run.checkpoint(run)
    assert {:ok, restored} = Run.restore(checkpoint)
    assert restored.id == run.id
    assert restored.state == run.state

    assert {:complete, _result, completed} = Runtime.advance(restored)
    assert completed.status == :complete
    refute Map.has_key?(completed.state.data, :directive)
  end
end
