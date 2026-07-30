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

  alias Spectre.Instance
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

  test "a passive installation runs under one subject Instance without owning its scheduler" do
    supervisor =
      start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    subject = "directive-instance-#{System.unique_integer([:positive])}"

    assert {:ok, instance} =
             Spectre.instance(supervisor, Agent, subject, idle: false)

    tasks =
      for input <- ["first passive Run", "second passive Run"] do
        Task.async(fn -> Spectre.ask(instance, input) end)
      end

    assert Enum.all?(
             Task.await_many(tasks, 5_000),
             &match?({:ok, %Spectre.Result{}}, &1)
           )

    assert_eventually(fn ->
      info = Instance.info(instance)

      map_size(info.runs) == 2 and info.ready == [] and
        is_nil(info.active_run) and info.invocations == %{} and
        Enum.all?(info.runs, fn {_id, run} -> run.status == :complete end)
    end)

    assert Spectre.state(instance).revision == 2
    refute Map.has_key?(Spectre.state(instance).data, :directive)

    assert [{_id, ^instance, :worker, [Instance]}] =
             DynamicSupervisor.which_children(supervisor)
  end

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
