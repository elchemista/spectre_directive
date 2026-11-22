defmodule DirectiveActivityExample.Model do
  @behaviour Spectre.LLM

  @impl true
  def complete(prompt, _opts) do
    if String.contains?(prompt, "DIRECTIVE_INPUT_JSON:"),
      do: mission_response(prompt),
      else: chat_response(prompt)
  end

  defp chat_response(prompt) do
    latest = prompt |> String.split("Latest message:") |> List.last()

    if String.contains?(latest, "Which project did I mention?") and
         String.contains?(prompt, "The project is Aurora.") do
      {:ok, "You mentioned Aurora."}
    else
      {:ok, "I am available to chat."}
    end
  end

  # The local provider fixture keeps the example reproducible without credentials.
  defp mission_response(prompt) do
    cond do
      String.contains?(prompt, "demonstrate provider failure") ->
        {:error, :example_provider_unavailable}

      String.contains?(prompt, "Focus on Italy") ->
        decision(:complete_mission, result: "The report will focus on Italy.")

      String.contains?(prompt, "Compare France and Germany") ->
        decision(:complete_mission, result: "The comparison will cover France and Germany.")

      true ->
        decision(:ask, question: "Which country should this mission focus on?")
    end
  end

  defp decision(kind, fields), do: {:ok, Spectre.JSON.encode!(Map.new([{:kind, kind} | fields]))}
end

defmodule DirectiveActivityExample.IntentModel do
  @behaviour Spectre.LLM

  @impl true
  def complete(prompt, _opts) do
    latest = prompt |> String.split("Latest message:") |> List.last()

    cond do
      String.contains?(latest, ["prepare a report", "compare our vendors", "provider failure"]) ->
        {:ok, "mission"}

      String.contains?(latest, ["Which project", "Aurora"]) ->
        {:ok, "chat"}

      true ->
        {:ok, "unrecognized"}
    end
  end
end

defmodule DirectiveActivityExample.Stack do
  use Spectre.Stack
  install(Spectre.Directive)
end

defmodule DirectiveActivityExample.Agent do
  use Spectre.Agent,
    stack: DirectiveActivityExample.Stack,
    server: DirectiveActivityExample.Server

  model(DirectiveActivityExample.Model)
  classifier(:llm, DirectiveActivityExample.IntentModel)
  router(strategies: [:llm_classifier])

  flow :assistant do
    on(:chat, semantic_examples: ["How are you?", "Remind me what we discussed"])
    on(:mission, semantic_examples: ["Compare these markets and prepare a report"])
  end
end

defmodule DirectiveActivityExample.Server do
  use Spectre.Server, prompt_root: Path.join(__DIR__, "prompts")

  def handle_flow({:assistant, :mission}, input, ctx) do
    start_activity(ctx, {:directive, :mission}, %{
      goal: input.text,
      context: %{recent_turns: Map.get(ctx.assigns, :turns, [])}
    })
  end

  def handle_flow({:assistant, :chat}, _input, ctx), do: chat(ctx)
  def handle_flow(:unmatched, _input, ctx), do: chat(ctx)

  def handle_result(:chat_reply, {:generated, %{text: text}}, ctx) do
    turns = Map.get(ctx.assigns, :turns, []) ++ [%{user: ctx.input.text, assistant: text}]
    ctx |> assign(:turns, Enum.take(turns, -6)) |> respond(text)
  end

  def handle_result(tag, result, ctx), do: super(tag, result, ctx)

  defp chat(ctx) do
    generate(ctx, :chat,
      assigns: %{recent_turns: Map.get(ctx.assigns, :turns, [])},
      on_result: :chat_reply
    )
  end
end

alias Spectre.Server

{:ok, root} = Server.start_link(agent: DirectiveActivityExample.Agent, consumer: self())

exchange = fn message, expected ->
  {:ok, turn} = Server.input(root, message)

  receive do
    {Server, ^root, {:response, ^turn, ^expected, _}} -> IO.puts(expected)
  after
    5_000 -> raise "The Root did not send the expected chat reply"
  end
end

start = fn command ->
  {:ok, _} = Server.input(root, command)

  receive do
    {Server, ^root, {:activity, %{ref: ref, key: nil}, :started}} -> ref
  after
    5_000 -> raise "The mission did not start"
  end
end

question = fn ref ->
  receive do
    {Server, ^root, {:activity, %{ref: ^ref}, {:waiting_input, %{prompt: prompt} = wait}}} ->
      IO.puts(prompt)
      wait
  after
    5_000 -> raise "The mission did not request input"
  end
end

complete = fn ref ->
  receive do
    {Server, ^root, {:activity, %{ref: ^ref}, {:completed, %{result: result}}}} -> IO.puts(result)
    {Server, ^root, {:activity, %{ref: ^ref}, {:failed, reason}}} -> raise inspect(reason)
  after
    5_000 -> raise "The mission did not finish"
  end
end

exchange.("The project is Aurora.", "I am available to chat.")
{:ok, []} = Server.activities(root)

report = start.("Please prepare a report on quarterly markets")
question.(report)

comparison = start.("Can you compare our vendors?")
comparison_wait = question.(comparison)
true = report != comparison

exchange.("Which project did I mention?", "You mentioned Aurora.")
exchange.("Thanks, how are you?", "I am available to chat.")

{:ok, %{revision: revision}} = Server.activity(root, report)

{:ok, signal} =
  Server.signal_activity(root, report, {:revise, "Focus on Italy"}, if_revision: revision)

receive do
  {Server, ^root, {:activity, %{ref: ^report}, {:signalled, ^signal, {:ok, _}}}} -> :ok
after
  5_000 -> raise "The revision was not applied"
end

{:ok, _} =
  Server.input(root, "Compare France and Germany",
    activity: comparison,
    pending: {comparison_wait.id, comparison_wait.revision}
  )

complete.(report)
complete.(comparison)

failed = start.("Could you demonstrate provider failure?")

receive do
  {Server, ^root, {:activity, %{ref: ^failed}, {:failed, :example_provider_unavailable}}} ->
    IO.puts("Reported the provider failure through the Activity lifecycle.")
after
  5_000 -> raise "The Activity did not report the provider failure"
end

GenServer.stop(root)
