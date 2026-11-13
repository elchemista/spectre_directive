defmodule Spectre.Directive.ServerToolTest do
  use ExUnit.Case, async: true
  alias Spectre.Directive.ServerTool

  test "pure mission crosses the Server boundary as canonical state and plain request" do
    attrs = %{mission: "Inspect a site", reasoner: :model}
    assert {:ok, ^attrs} = ServerTool.prepare(:new, [attrs], %{})
    raw = ServerTool.invoke(:new, attrs, %{})

    assert {:ok, {:directive, %{status: :request, state: encoded, data: request}}} =
             ServerTool.project(:new, raw)

    assert request.kind == :reason
    assert is_binary(encoded)
    assert :ok = Spectre.GAM.Canonical.Value.validate(request)
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
    assert :ok = Spectre.GAM.Canonical.Value.validate(result)
  end
end
