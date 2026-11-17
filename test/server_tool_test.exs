defmodule Spectre.Directive.ServerToolTest do
  use ExUnit.Case, async: true
  alias Spectre.Directive.ServerTool
  alias Spectre.GAM.Canonical.Value

  test "pure mission crosses the Server boundary as canonical state and plain request" do
    attrs = %{mission: "Inspect a site", reasoner: :model}
    assert {:ok, ^attrs} = ServerTool.prepare(:new, [attrs], %{})
    raw = ServerTool.invoke(:new, attrs, %{})

    assert {:ok, {:directive, %{status: :request, state: encoded, data: request}}} =
             ServerTool.project(:new, raw)

    assert request.kind == :reason
    assert is_binary(encoded)
    assert :ok = Value.validate(request)
    assert {:ok, args} = ServerTool.prepare(:next, [encoded], %{})

    assert {:ok, {:directive, %{data: replayed}}} =
             ServerTool.project(:next, ServerTool.invoke(:next, args, %{}))

    assert replayed.id == request.id
  end

  test "unknown or stale request cannot advance the pure mission" do
    {:ok, {:directive, %{state: encoded}}} =
      ServerTool.project(
        :new,
        ServerTool.invoke(:new, %{mission: "Research", reasoner: :model}, %{})
      )

    {:ok, args} = ServerTool.prepare(:respond, [encoded, "stale", {:done, :ok}], %{})

    assert {:ok, {:directive, %{status: :error}}} =
             ServerTool.project(:respond, ServerTool.invoke(:respond, args, %{}))

    assert {:error, _} = ServerTool.prepare(:next, ["not canonical"], %{})
  end

  test "no automatic executor or callback function enters a durable tool result" do
    raw =
      ServerTool.invoke(
        :new,
        %{mission: "Research", reasoner: fn _ -> send(self(), :executed) end},
        %{}
      )

    assert {:error, _} = ServerTool.project(:new, raw)
    refute_received :executed

    assert Enum.all?(Spectre.Directive.tools(%{}).directive.operations, fn {_op, descriptor} ->
             descriptor.path == :cognitive
           end)
  end

  test "invalid mission attributes remain a portable domain error" do
    raw = ServerTool.invoke(:new, %{mission: "Research", assigns: 123}, %{})
    assert {:ok, {:error, _} = result} = ServerTool.project(:new, raw)
    assert :ok = Value.validate(result)
  end

  test "new information refreshes serialized reasoning and a portable outcome can complete it" do
    {:ok, {:directive, %{state: encoded, data: original}}} =
      ServerTool.project(
        :new,
        ServerTool.invoke(:new, %{mission: "Research", reasoner: :model}, %{})
      )

    evidence = %{labels: MapSet.new([:verified]), observed_at: ~U[2026-11-17 10:00:00Z]}
    assert {:ok, args} = ServerTool.prepare(:inform, [encoded, evidence], %{})

    assert {:ok, {:directive, %{status: :request, state: informed, data: request}}} =
             ServerTool.project(:inform, ServerTool.invoke(:inform, args, %{}))

    refute request.id == original.id

    assert request.context.last_result == %{
             labels: [:verified],
             observed_at: "2026-11-17T10:00:00Z"
           }

    assert {:ok, state} = ServerTool.decode(informed)
    assert state.working_context.last_result == evidence

    assert {:ok, args} =
             ServerTool.prepare(
               :respond,
               [informed, request.id, {:complete_mission, evidence}],
               %{}
             )

    assert {:ok, {:directive, %{status: :done, data: outcome}}} =
             ServerTool.project(:respond, ServerTool.invoke(:respond, args, %{}))

    assert outcome.status == :completed
    assert outcome.result == request.context.last_result
  end

  test "malformed tool requests and nonportable results cannot become checkpoints" do
    assert {:error, :invalid_directive_request} = ServerTool.prepare(:new, [[]], %{})

    assert {:error, :invalid_directive_request} =
             ServerTool.prepare(:respond, ["state", 1, :ok], %{})

    assert {:ok, encoded} = Value.encode(%{mission: "Not a loop state"})
    assert {:error, :invalid_directive_state} = ServerTool.decode(encoded)
    assert {:error, :invalid_directive_result} = ServerTool.project(:new, :unexpected)

    for result <- [%{live_handle: self()}, [fn -> send(self(), :executed) end]] do
      assert {:error, _} = ServerTool.project(:new, {:error, result})
    end

    refute_received :executed
  end
end
