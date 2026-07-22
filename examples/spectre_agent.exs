defmodule SpectreDirective.Examples.ProfileAgent do
  @moduledoc false

  # Order matters: Directive detects the existing Spectre Agent at compile
  # time and adds its private reasoning route to the Agent's normal routes.
  use Spectre.Agent
  use Spectre.Directive

  alias SpectreDirective.Context
  alias SpectreDirective.Information

  directive "personal-greeting" do
    mission "Ask for the missing profile fields and create a greeting"
    context "The host owns the user conversation and every executable effect."
    success "Return one personalized greeting"
    mode :autonomous
    directive_metadata %{owner: :examples}

    on_complete fn context ->
      # This is the application-owned completion boundary: persist, publish,
      # notify, or enqueue follow-up work here. Its result is kept separately.
      {:ok, %{recorded: context.last_result}}
    end
  end

  # These clauses provide deterministic reasoning for the example. If they
  # are omitted, the default handler asks the Spectre Agent's configured model
  # using Directive's provider-neutral JSON protocol.
  @impl Spectre.Directive.Handler
  def handle_directive({:reason, %Context{operation: :plan}}, _spectre_context) do
    {:propose_plan,
     [
       %{id: "profile", title: "Collect the missing profile fields"},
       %{id: "greeting", title: "Build the greeting", invoke: "build_greeting"}
     ]}
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

  # A model may propose a symbolic name, but only this host callback can turn
  # it into executable BEAM code. Unknown names fail closed.
  def handle_directive({:invocation, "build_greeting"}, _context) do
    {:ok,
     fn context ->
       [name, language | _rest] = answers(context)

       {:complete_step,
        %{
          greeting: "Hello, #{name}!",
          language: language,
          source: :application
        }}
     end}
  end

  def handle_directive({:invocation, target}, _context),
    do: {:error, {:unknown_invocation, target}}

  def handle_directive(message, context), do: super(message, context)

  defp answers(%Context{} = context) do
    for %Information{source: {:answer, _request_id}, content: answer} <- context.information,
        do: answer
  end
end

alias SpectreDirective.Examples.ProfileAgent
alias SpectreDirective.Outcome
alias SpectreDirective.Request

{:ok, mission} = ProfileAgent.start_directive("personal-greeting")

# A CLI, LiveView, bot adapter, or other host presents each returned request
# to the real user. The fixed answers keep this repository example runnable.
{:ok, {:request, %Request{} = request}} = Spectre.Directive.await_input(mission)
IO.puts("Agent asks: #{request.payload.question}")

{:ok, {:request, %Request{} = request}} = Spectre.Directive.reply(mission, "Ada")
IO.puts("Agent asks again: #{request.payload.question}")

{:ok, {:outcome, %Outcome{} = outcome}} = Spectre.Directive.reply(mission, "Italian")

IO.inspect(outcome.result, label: "mission result")
IO.inspect(outcome.completion_result, label: "completion callback result")

:ok = Spectre.Directive.stop(mission)
