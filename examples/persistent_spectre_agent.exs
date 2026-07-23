defmodule SpectreDirective.Examples.PersistentStore do
  @moduledoc false

  @behaviour Spectre.Directive.Store

  @name __MODULE__
  @terminal [:completed, :failed, :cancelled]

  def open do
    case Agent.start_link(fn -> %{} end, name: @name) do
      {:ok, agent} -> agent
      {:error, {:already_started, agent}} -> agent
    end
  end

  @impl true
  def load(key, _opts) do
    Agent.get(@name, &{:ok, Map.get(&1, key)})
  end

  @impl true
  def snapshot(key, next, _opts) do
    Agent.get_and_update(@name, fn snapshots ->
      case Map.fetch(snapshots, key) do
        :error when next.revision == 1 ->
          {:ok, Map.put(snapshots, key, next)}

        {:ok, current} when current == next ->
          {:ok, snapshots}

        {:ok, current}
        when current.state.status in @terminal and next.revision == 1 ->
          {:ok, Map.put(snapshots, key, next)}

        {:ok, current}
        when current.state.mission.id == next.state.mission.id and
               next.revision == current.revision + 1 ->
          {:ok, Map.put(snapshots, key, next)}

        {:ok, current} ->
          {{:error, {:stale_snapshot, current.revision, next.revision}}, snapshots}
      end
    end)
  end
end

defmodule SpectreDirective.Examples.PersistentProfileAgent do
  @moduledoc false

  use Spectre.Agent

  use Spectre.Directive,
    store: SpectreDirective.Examples.PersistentStore,
    store_namespace: :profile_example

  alias SpectreDirective.Context
  alias SpectreDirective.Information

  directive "profile" do
    mission("Collect a name and preferred language through ordinary Spectre turns")
    success("Return the completed profile")
    mode(:guided)

    on_complete(fn context ->
      {:ok, %{stored: context.last_result}}
    end)
  end

  flow :entry do
    on :START_PROFILE, regex: ~r/^start profile$/i do
      run(:start_profile)
    end

    on :HELLO, regex: ~r/^hello$/i do
      run(:hello)
    end
  end

  def start_profile(input, spectre_context) do
    start_directive_turn("profile", input, spectre_context)
  end

  def hello(_input), do: "Normal Spectre routing is active again."

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

alias SpectreDirective.Examples.PersistentProfileAgent, as: ProfileAgent
alias SpectreDirective.Examples.PersistentStore

PersistentStore.open()
conversation_id = "profile-example-42"

for {message, turn_id} <- [
      {"start profile", "profile-message-1"},
      {"yes", "profile-message-2"},
      {"Ada", "profile-message-3"},
      {"Italian", "profile-message-4"}
    ] do
  {:ok, result} =
    Spectre.ask(ProfileAgent, message,
      conversation_id: conversation_id,
      turn_id: turn_id
    )

  IO.puts("#{message} -> #{result.reply_text}")
end

{:ok, replayed} =
  Spectre.ask(ProfileAgent, "Italian",
    conversation_id: conversation_id,
    turn_id: "profile-message-4"
  )

IO.puts("retried profile-message-4 -> #{replayed.reply_text}")

{:ok, routed} =
  Spectre.ask(ProfileAgent, "hello",
    conversation_id: conversation_id,
    turn_id: "profile-message-5"
  )

IO.puts("hello -> #{routed.reply_text}")

{:ok, terminal} = PersistentStore.load({:profile_example, "profile-example-42"}, [])
IO.inspect(terminal.state.outcome.result, label: "persisted outcome")
IO.inspect(terminal.state.plan, label: "persisted final plan")
