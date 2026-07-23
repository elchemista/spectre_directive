defmodule SpectreDirective.StoreTest.Store do
  @moduledoc false

  @behaviour Spectre.Directive.Store

  @impl Spectre.Directive.Store
  def load(key, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:store_load, key, opts})

    case Keyword.get(opts, :load_mode, :value) do
      :value -> {:ok, Keyword.get(opts, :stored_snapshot)}
      :error -> {:error, :database_down}
      :invalid -> :missing
      :raise -> raise "store private failure"
    end
  end

  @impl Spectre.Directive.Store
  def snapshot(key, snapshot, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:store_snapshot, key, snapshot, opts})

    case Keyword.get(opts, :snapshot_mode, :ok) do
      :ok -> :ok
      :error -> {:error, :write_failed}
      :invalid -> {:ok, :unexpected}
      :exit -> exit(:store_exit)
    end
  end
end

defmodule SpectreDirective.StoreTest do
  use ExUnit.Case, async: true

  alias Spectre.Directive.Snapshot
  alias Spectre.Directive.Store
  alias SpectreDirective.Loop.Engine
  alias SpectreDirective.Loop.State
  alias SpectreDirective.StoreTest.Store, as: TestStore

  setup do
    {:ok, state} = State.new(mission: "Persist the mission", steps: [%{title: "First"}])
    snapshot = Snapshot.new({:agent, "conversation-1"}, state, runtime_opts: [execution: :auto])
    %{snapshot: snapshot, state: state}
  end

  test "a snapshot contains the complete mission and living plan", %{snapshot: snapshot} do
    assert snapshot.version == 1
    assert snapshot.revision == 1
    assert snapshot.key == {:agent, "conversation-1"}
    assert snapshot.state.mission.goal == "Persist the mission"
    assert [%{title: "First"}] = snapshot.state.plan.steps
    assert snapshot.runtime_opts == [execution: :auto]
    assert %DateTime{} = snapshot.snapshotted_at
    assert snapshot.last_turn_id == nil
    assert snapshot.turn_receipts == %{}
    assert Snapshot.active?(snapshot)
    assert Snapshot.validate(snapshot, snapshot.key) == :ok
  end

  test "a snapshot records and safely replays one stable external turn", %{snapshot: snapshot} do
    input = %{text: "yes"}
    boundary = {:request, %{kind: :confirmation}}
    recorded = Snapshot.record_turn(snapshot, "message-1", input, boundary, "Please confirm.")

    assert {:ok, turn} = Snapshot.replay(recorded, "message-1", input)
    assert turn.id == "message-1"
    assert turn.boundary == boundary
    assert turn.reply_text == "Please confirm."
    assert :miss = Snapshot.replay(recorded, "message-2", input)

    assert {:error, {:directive_turn_id_reused, "message-1"}} =
             Snapshot.replay(recorded, "message-1", %{text: "different"})

    assert Snapshot.validate(recorded, snapshot.key) == :ok
  end

  test "terminal snapshots remain valid but are inactive", %{snapshot: snapshot, state: state} do
    terminal = Engine.cancel(state, :user_cancelled)
    refreshed = Snapshot.refresh(snapshot, terminal)

    assert refreshed.revision == 2
    refute Snapshot.active?(refreshed)
    assert refreshed.state.status == :cancelled
    assert refreshed.state.outcome.reason == :user_cancelled
    assert Snapshot.validate(refreshed, snapshot.key) == :ok
  end

  test "Store targets merge fixed and per-call options and validate keys", %{snapshot: snapshot} do
    target = {TestStore, [test_pid: self(), fixed: true]}

    assert {:ok, ^snapshot} =
             Store.load(target, snapshot.key,
               stored_snapshot: snapshot,
               runtime: true
             )

    assert_receive {:store_load, key, load_opts}
    assert key == snapshot.key
    assert load_opts[:fixed]
    assert load_opts[:runtime]

    assert :ok = Store.snapshot(target, snapshot.key, snapshot, runtime: true)
    assert_receive {:store_snapshot, ^key, ^snapshot, snapshot_opts}
    assert snapshot_opts[:fixed]
    assert snapshot_opts[:runtime]

    wrong = %{snapshot | key: {:agent, "other"}}

    assert {:error, {:snapshot_key_mismatch, ^key, {:agent, "other"}}} =
             Store.load(target, key, stored_snapshot: wrong)
  end

  test "Store preserves declared errors and contains callback failures", %{snapshot: snapshot} do
    target = {TestStore, test_pid: self()}

    assert {:error, :database_down} = Store.load(target, snapshot.key, load_mode: :error)

    assert {:error, {:directive_store_exception, TestStore, :load, RuntimeError}} =
             Store.load(target, snapshot.key, load_mode: :raise)

    assert {:error, :write_failed} =
             Store.snapshot(target, snapshot.key, snapshot, snapshot_mode: :error)

    assert {:error, {:directive_store_failure, TestStore, :snapshot, :exit, :store_exit}} =
             Store.snapshot(target, snapshot.key, snapshot, snapshot_mode: :exit)
  end

  test "Store rejects malformed adapters, replies, options, and snapshots", %{snapshot: snapshot} do
    target = {TestStore, test_pid: self()}

    assert {:error, {:invalid_directive_store_load_reply, :atom}} =
             Store.load(target, snapshot.key, load_mode: :invalid)

    assert {:error, {:invalid_directive_store_snapshot_reply, :tuple}} =
             Store.snapshot(target, snapshot.key, snapshot, snapshot_mode: :invalid)

    assert {:error, {:undefined_directive_store, String}} = Store.load(String, :key)
    assert {:error, {:invalid_store_options, :map}} = Store.load(target, :key, %{})

    assert {:error, {:invalid_directive_snapshot, :map}} =
             Store.snapshot(target, :key, %{})
  end
end
