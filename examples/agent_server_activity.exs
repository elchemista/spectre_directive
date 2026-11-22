defmodule DirectiveActivityExample.Model do
  @behaviour Spectre.LLM

  @impl true
  def complete(prompt, _opts) do
    # A deterministic provider makes the lifecycle reproducible without credentials.
    decision =
      if String.contains?(inspect(prompt, printable_limit: :infinity), "Focus on Italy") do
        %{kind: "complete_mission", result: "The report will focus on Italy."}
      else
        %{kind: "ask", question: "Which country should the report focus on?"}
      end

    {:ok, Spectre.JSON.encode!(decision)}
  end
end

defmodule DirectiveActivityExample.Stack do
  use Spectre.Stack
  install(Spectre.Directive)
end

defmodule DirectiveActivityExample.Server do
  use Spectre.Server

  def handle_flow({:research, :start}, %Spectre.Input{text: "research " <> goal}, ctx),
    do: start_activity(ctx, {:directive, :mission}, %{goal: goal})

  def handle_flow({:research, :ping}, _input, ctx), do: respond(ctx, "The Root is available.")
  def handle_flow(flow, input, ctx), do: super(flow, input, ctx)
end

defmodule DirectiveActivityExample.Agent do
  use Spectre.Agent,
    stack: DirectiveActivityExample.Stack,
    server: DirectiveActivityExample.Server

  model(DirectiveActivityExample.Model)
  router(strategies: [:regex])

  flow :research do
    on(:start, regex: ~r/^research .+$/)
    on(:ping, regex: ~r/^ping$/)
  end
end

alias Spectre.Server

{:ok, root} = Server.start_link(agent: DirectiveActivityExample.Agent, consumer: self())
{:ok, _} = Server.input(root, "research the quarterly market report")

{ref, wait} =
  receive do
    {Server, ^root, {:activity, %{ref: ref}, {:waiting_input, %{prompt: question} = wait}}} ->
      IO.puts(question)
      {ref, wait}
  after
    5_000 -> raise "The mission did not request input"
  end

{:ok, turn} = Server.input(root, "ping")

receive do
  {Server, ^root, {:response, ^turn, text, _}} -> IO.puts(text)
after
  5_000 -> raise "The Root did not answer"
end

{:ok, _} = Server.input(root, "Focus on Italy", activity: ref, pending: {wait.id, wait.revision})

receive do
  {Server, ^root, {:activity, %{ref: ^ref}, {:completed, %{result: result}}}} -> IO.puts(result)
  {Server, ^root, {:activity, %{ref: ^ref}, {:failed, reason}}} -> raise inspect(reason)
after
  5_000 -> raise "The mission did not finish"
end

GenServer.stop(root)
