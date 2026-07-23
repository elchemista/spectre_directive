defmodule SpectreDirective.PersistentConversationStore do
  @moduledoc false

  @behaviour Spectre.Directive.Store

  @table :spectre_directive_persistent_conversation_test

  @impl Spectre.Directive.Store
  def load(key, _opts) do
    case :ets.lookup(@table, key) do
      [{^key, snapshot}] -> {:ok, snapshot}
      [] -> {:ok, nil}
    end
  end

  @impl Spectre.Directive.Store
  def snapshot(key, snapshot, _opts) do
    true = :ets.insert(@table, {key, snapshot})
    :ok
  end
end

defmodule SpectreDirective.PersistentConversationAgent do
  @moduledoc false

  use Spectre.Agent
  use Spectre.Directive, store: SpectreDirective.PersistentConversationStore

  alias SpectreDirective.Context
  alias SpectreDirective.Information

  directive "profile" do
    mission("Collect two profile fields through ordinary Spectre turns")
    mode(:guided)

    on_complete(fn context -> {:ok, %{stored: context.last_result}} end)
  end

  flow :entry do
    on :START, regex: ~r/^start$/ do
      run(:start_profile)
    end

    on :NORMAL, regex: ~r/^hello$/ do
      run(:normal_reply)
    end
  end

  def start_profile(input, spectre_context) do
    start_directive_turn("profile", input, spectre_context,
      spectre_opts: [conversation_id: spectre_context.opts[:conversation_id]]
    )
  end

  def normal_reply(_input), do: "normal Spectre route"

  @impl Spectre.Directive.Handler
  def handle_directive({:reason, %Context{operation: :plan}}, _spectre_context) do
    {:propose_plan, [%{id: "profile", title: "Collect the profile"}]}
  end

  def handle_directive({:reason, %Context{operation: :step} = context}, _spectre_context) do
    case answers(context) do
      [] -> {:ask, "What is your name?"}
      [_name] -> {:ask, "Which language do you prefer?"}
      [name, language | _rest] -> {:complete_step, %{name: name, language: language}}
    end
  end

  def handle_directive(
        {:reason, %Context{operation: :mission_review} = context},
        _spectre_context
      ) do
    {:complete_mission, context.last_result}
  end

  def handle_directive(message, context), do: super(message, context)

  defp answers(%Context{} = context) do
    for %Information{source: {:answer, _request_id}, content: answer} <- context.information,
        do: answer
  end
end

defmodule SpectreDirective.PersistentSpectreConversationTest do
  use ExUnit.Case, async: false

  alias Spectre.Directive.Snapshot
  alias SpectreDirective.Information
  alias SpectreDirective.PersistentConversationAgent, as: Agent
  alias SpectreDirective.PersistentConversationStore, as: Store
  alias SpectreDirective.Request

  @table :spectre_directive_persistent_conversation_test
  @turn_handler SpectreDirective.Integration.SpectreAgent.TurnHandler

  setup do
    table = :ets.new(@table, [:named_table, :public, :set])
    on_exit(fn -> if :ets.whereis(@table) != :undefined, do: :ets.delete(@table) end)
    %{table: table}
  end

  test "ordinary Spectre.ask turns resume questions and persist the plan through completion" do
    conversation_opts = [conversation_id: "profile-42"]
    key = {Agent, "profile-42"}

    assert [{@turn_handler, handler_opts}] =
             Keyword.fetch!(Agent.__spectre_config__(), :turn_handlers)

    assert handler_opts[:owner] == Agent
    assert handler_opts[:store] == Store

    start_opts = Keyword.put(conversation_opts, :turn_id, "profile-start")
    assert {:ok, started} = Spectre.ask(Agent, "start", start_opts)
    assert started.route.label == :START
    assert started.reply_text == "Please confirm the proposed plan."
    assert started.metadata.spectre_directive.status == :waiting

    assert {:request, %Request{kind: :confirmation}} =
             started.metadata.spectre_directive.boundary

    assert [{^key, %Snapshot{} = first_snapshot}] = :ets.lookup(@table, key)
    assert first_snapshot.state.plan.version == 1
    assert first_snapshot.revision == 1
    assert first_snapshot.state.status == :waiting
    assert first_snapshot.state.pending_request.kind == :confirmation
    assert first_snapshot.last_turn_id == "profile-start"
    assert {:error, :not_found} = Spectre.Directive.state(first_snapshot.state.mission.id)

    assert {:ok, replayed_start} = Spectre.ask(Agent, "start", start_opts)
    assert replayed_start.route == nil
    assert replayed_start.reply_text == started.reply_text
    assert replayed_start.metadata.spectre_directive.replayed?
    assert [{^key, %Snapshot{revision: 1}}] = :ets.lookup(@table, key)

    confirmation_opts = Keyword.put(conversation_opts, :turn_id, "profile-confirm")
    assert {:ok, first_question} = Spectre.ask(Agent, "yes", confirmation_opts)
    assert first_question.route == nil
    assert first_question.reply_text == "What is your name?"
    assert first_question.metadata.turn_handler == @turn_handler
    assert first_question.metadata.spectre_directive.status == :waiting

    assert {:request, %Request{kind: :question}} =
             first_question.metadata.spectre_directive.boundary

    assert {:ok, replayed_question} = Spectre.ask(Agent, "yes", confirmation_opts)
    assert replayed_question.reply_text == first_question.reply_text
    assert replayed_question.metadata.spectre_directive.replayed?
    assert [{^key, %Snapshot{revision: 2}}] = :ets.lookup(@table, key)

    name_opts = Keyword.put(conversation_opts, :turn_id, "profile-name")
    assert {:ok, second_question} = Spectre.ask(Agent, "Ada", name_opts)
    assert second_question.reply_text == "Which language do you prefer?"
    assert second_question.metadata.spectre_directive.plan_version == 2

    assert {:ok, delayed_duplicate} = Spectre.ask(Agent, "yes", confirmation_opts)
    assert delayed_duplicate.reply_text == first_question.reply_text
    assert delayed_duplicate.metadata.spectre_directive.replayed?
    assert delayed_duplicate.metadata.spectre_directive.turn_id == "profile-confirm"
    assert delayed_duplicate.metadata.spectre_directive.snapshot_revision == 2
    assert [{^key, %Snapshot{revision: 3}}] = :ets.lookup(@table, key)

    language_opts = Keyword.put(conversation_opts, :turn_id, "profile-language")
    assert {:ok, completed} = Spectre.ask(Agent, "Italian", language_opts)
    assert completed.route == nil
    assert completed.reply_text == "Mission completed."
    assert completed.metadata.spectre_directive.status == :completed
    assert {:outcome, outcome} = completed.metadata.spectre_directive.boundary
    assert outcome.result == %{name: "Ada", language: "Italian"}
    assert outcome.completion_result == %{stored: outcome.result}

    assert [{^key, %Snapshot{} = terminal}] = :ets.lookup(@table, key)
    refute Snapshot.active?(terminal)
    assert terminal.revision == 4
    assert terminal.state.status == :completed

    assert {:ok, replayed_completion} = Spectre.ask(Agent, "Italian", language_opts)
    assert replayed_completion.reply_text == completed.reply_text
    assert replayed_completion.metadata.spectre_directive.status == :completed
    assert replayed_completion.metadata.spectre_directive.replayed?
    assert [{^key, %Snapshot{revision: 4}}] = :ets.lookup(@table, key)

    assert [
             %Information{content: "Ada"},
             %Information{content: "Italian"}
           ] =
             Enum.filter(terminal.state.working_context.information, fn
               %Information{source: {:answer, _request_id}} -> true
               _information -> false
             end)

    assert {:ok, routed} = Spectre.ask(Agent, "hello", conversation_opts)
    assert routed.route.label == :NORMAL
    assert routed.reply_text == "normal Spectre route"
  end

  test "reusing one turn id for different input fails closed" do
    opts = [conversation_id: "reused-id", turn_id: "message-1"]
    assert {:ok, _started} = Spectre.ask(Agent, "start", opts)

    assert {:error, {:directive_turn_id_reused, "message-1"}} =
             Spectre.ask(Agent, "different", opts)
  end

  test "starting a persisted Directive requires a stable conversation id" do
    assert {:error, :directive_conversation_id_required} = Spectre.ask(Agent, "start")
    assert :ets.tab2list(@table) == []
  end

  test "a structured response in input metadata reaches the pending request unchanged" do
    opts = [conversation_id: "structured"]
    assert {:ok, started} = Spectre.ask(Agent, "start", opts)
    assert {:request, %Request{kind: :confirmation}} = started.metadata.spectre_directive.boundary

    input = %{
      text: "custom UI payload",
      meta: %{spectre_directive_response: :accept}
    }

    assert {:ok, question} = Spectre.ask(Agent, input, opts)
    assert question.reply_text == "What is your name?"
  end
end
