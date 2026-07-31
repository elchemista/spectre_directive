defmodule SpectreDirective.CompatibilityFixtureTest do
  use ExUnit.Case, async: true

  alias Spectre.Directive.Snapshot
  alias SpectreDirective.Information
  alias SpectreDirective.Loop.State
  alias SpectreDirective.Mission
  alias SpectreDirective.Plan
  alias SpectreDirective.Request
  alias SpectreDirective.Step
  alias SpectreDirective.Trace.Entry
  alias SpectreDirective.WorkingContext

  @fixture Path.expand(
             "fixtures/compatibility/0.1.6/directive-snapshot-v1.term.base64",
             __DIR__
           )

  @fixture_atoms [
    :accepted,
    :application,
    :ask,
    :authored,
    :baseline,
    :compatibility,
    :confirmation,
    :directive,
    :execution,
    :fixture,
    :fixture_restores,
    :guided,
    :locale,
    :locked,
    :manual,
    :no_breaking_changes,
    :no_new_features,
    :question,
    :request,
    :running,
    :step,
    :trusted,
    :waiting
  ]

  @fixture_modules [
    Snapshot,
    State,
    Mission,
    Plan,
    Request,
    Step,
    Entry,
    Information,
    WorkingContext,
    SpectreDirective.Context,
    DateTime,
    Calendar.ISO,
    Spectre.Directive
  ]

  test "the permanent Directive snapshot v1 restores complete mission state" do
    _loaded_atoms = @fixture_atoms
    snapshot = read_fixture()

    assert %Snapshot{
             version: 1,
             revision: 3,
             key: {Spectre.Directive, "conversation-42"},
             runtime_opts: [execution: :manual],
             snapshotted_at: ~U[2026-07-31 08:30:00Z],
             last_turn_id: "message-1",
             metadata: %{directive: :compatibility, fixture: "0.1.6"},
             state: %State{
               status: :waiting,
               mode: :guided,
               iteration: 2,
               max_iterations: 10,
               pending_request: %Request{
                 id: "request-0.1.6-1",
                 kind: :question,
                 plan_version: 2
               }
             }
           } = snapshot

    assert :ok = Snapshot.validate(snapshot, snapshot.key)
    assert snapshot.state.mission.id == "mission-0.1.6"
    assert snapshot.state.mission.goal == "Preserve the Directive baseline"
    assert snapshot.state.plan.id == "plan-0.1.6"
    assert snapshot.state.plan.current_step_id == "step-0.1.6-1"

    assert [
             %Information{
               id: "info-0.1.6-1",
               source: :application,
               trust: :trusted
             }
           ] = snapshot.state.working_context.information

    assert {:ok, recorded} = Snapshot.replay(snapshot, "message-1", "continue")
    assert recorded.reply_text == "Continue?"
    assert recorded.snapshot_revision == 3
    assert recorded.plan_version == 2
  end

  defp read_fixture do
    Enum.each(@fixture_modules, &Code.ensure_loaded!/1)

    @fixture
    |> File.read!()
    |> String.replace(~r/\s+/, "")
    |> Base.decode64!()
    # This is a reviewed, repository-owned fixture for Directive's explicitly
    # trusted snapshot boundary, never an untrusted wire payload.
    |> :erlang.binary_to_term()
  end
end
