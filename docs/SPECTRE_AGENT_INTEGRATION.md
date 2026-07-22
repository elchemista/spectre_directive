# Integrating with Spectre Agent

Spectre Agent and Spectre Directive own different parts of an interaction:

```text
user/channel <-> application host <-> Directive mission <-> Spectre Agent reasoning
```

- Spectre Agent performs one internal reasoning turn and returns a Directive
  decision such as `{:ask, question}`, `{:complete_step, result}`, or
  `{:complete_mission, result}`.
- Directive keeps the multi-step mission, accumulated answers, plan, and
  terminal outcome.
- The application host owns the real user channel. It displays questions and
  sends answers back to the same mission.

An answer to a pending Directive question is not a new `Spectre.ask/3` turn.
Send it to `Spectre.Directive.reply/3` or `respond/3`; otherwise Spectre will
route it as an unrelated Agent input and the mission will remain waiting.

## Define an Agent-backed directive

Put `use Spectre.Agent` before `use Spectre.Directive` so Directive can add its
private reasoning route during compilation:

```elixir
defmodule MyApp.ProfileAgent do
  use Spectre.Agent,
    model: MyApp.Models.default()

  use Spectre.Directive

  directive "profile" do
    mission "Collect the missing profile fields"
    success "Return a complete profile"
    mode :autonomous

    on_complete {MyApp.Profiles, :store, []}
  end

  @impl Spectre.Directive.Handler
  def handle_directive({:invocation, "lookup_account"}, _context) do
    {:ok, &MyApp.Accounts.lookup_from_directive/1}
  end

  def handle_directive({:invocation, name}, _context),
    do: {:error, {:unknown_invocation, name}}

  def handle_directive(message, context), do: super(message, context)
end
```

The generated `start_directive/2` starts an automatic Directive runtime whose
reasoner is this Agent:

```elixir
{:ok, mission} =
  MyApp.ProfileAgent.start_directive("profile",
    input: %{account_id: 42}
  )
```

The default `handle_directive({:reason, context}, spectre_context)` uses the
model configured by Spectre. Override that callback when reasoning comes from
deterministic application code or another adapter.

## A synchronous CLI or test loop

`await_input/2` hides transient `:reason` and `:invoke` work. It returns the
next boundary owned by the user/application, or the terminal outcome:

```elixir
case Spectre.Directive.await_input(mission) do
  {:ok, {:request, request}} -> present(request)
  {:ok, {:outcome, outcome}} -> deliver(outcome)
  {:error, reason} -> handle_runtime_error(reason)
end
```

`reply/3` answers the current request and waits for the next one. Repeating it
is enough for an Agent to request additional information:

```elixir
{:ok, {:request, first}} = Spectre.Directive.await_input(mission)
IO.puts(first.payload.question)

{:ok, {:request, second}} = Spectre.Directive.reply(mission, "Ada")
IO.puts(second.payload.question)

{:ok, {:outcome, outcome}} = Spectre.Directive.reply(mission, "Italian")
IO.inspect(outcome.result)
```

The Agent sees each answer on its next reasoning turn in
`context.information`. User answers are ordered and identifiable by their
source:

```elixir
answers =
  for %SpectreDirective.Information{
        source: {:answer, _request_id},
        content: answer
      } <- context.information,
      do: answer

case answers do
  [] -> {:ask, "What is your name?"}
  [_name] -> {:ask, "Which language do you prefer?"}
  [name, language | _] -> {:complete_step, %{name: name, language: language}}
end
```

The synchronous helpers return three user-owned request kinds:

| Kind | Present to the user | Valid response examples |
| --- | --- | --- |
| `:question` | `request.payload.question` | Any application value |
| `:confirmation` | `proposal_type` and `proposal` | `:accept`, `{:edit, plan}`, `{:reject, reason}` |
| `:policy` | `policy`, invocation, and purpose | `:allow`, `:deny`, or a host-specific decision |

Use `request.id` with `respond/3` when correlation must remain explicit.
`reply/3` deliberately refuses internal `:reason` and `:invoke` requests.
These helpers fit Agent missions because `start_directive/2` uses automatic
execution. A fully manual runtime must resolve its own reason and invocation
requests and may otherwise time out here.

## An event-driven LiveView, bot, or GenServer

Do not block a UI process with `await_input/2`. Subscribe when the mission is
started and keep the active `mission_id` and `request.id` in application state:

```elixir
{:ok, mission} =
  MyApp.ProfileAgent.start_directive("profile",
    subscribers: [channel_pid]
  )

receive do
  {:spectre_directive, mission_id, :request, request} ->
    MyApp.Channel.present(mission_id, request)

  {:spectre_directive, mission_id, :outcome, outcome} ->
    MyApp.Channel.complete(mission_id, outcome)

  {:spectre_directive, mission_id, :error, reason} ->
    MyApp.Channel.runtime_error(mission_id, reason)
end
```

When the user replies, correlate the channel/conversation to its active
mission and pending request:

```elixir
def handle_user_text(conversation_id, text) do
  case MyApp.ActiveMissions.get(conversation_id) do
    %{mission_id: mission_id, request_id: request_id} ->
      Spectre.Directive.respond(mission_id, request_id, text)

    nil ->
      Spectre.ask(MyApp.ProfileAgent, text)
  end
end
```

The next `:request` event may be another question. The `:outcome` event ends
the conversation. `subscribe/2` replays the current request or outcome, so a
reconnected process can attach to a live mission without guessing its state.

`request_handler` is useful when a synchronous function or service can answer
requests automatically. It is usually the wrong abstraction for a UI that
must wait an arbitrary amount of time for a person; use subscription events
and `respond/3` for that case. Do not configure both an automatic handler and
a human channel for the same request kind, because they would race to answer
the same correlated request.

## Completing the mission

The reasoner completes the core mission with:

```elixir
{:complete_mission, final_result}
```

If the directive declares `on_complete`, Directive runs that trusted callback
after the core result is ready. This boundary is appropriate for persistence,
notification, publishing, or enqueueing follow-up work:

```elixir
directive "profile" do
  mission "Collect a profile"

  on_complete fn context ->
    MyApp.Profiles.store(context.last_result)
  end
end
```

The terminal `%SpectreDirective.Outcome{}` keeps the values separate:

- `outcome.result` is the result supplied by `{:complete_mission, value}`;
- `outcome.completion_result` is the normalized `on_complete` result;
- `outcome.status` is `:completed`, `:failed`, or `:cancelled`;
- `outcome.reason` explains a failure or cancellation.

An `on_complete` error or timeout fails the mission rather than hiding a
failed side effect behind a successful result. After the application has
stored or delivered the outcome, call `Spectre.Directive.stop/1` to remove the
live mission process. Its state remains inspectable until then.

## Generated tools remain host-owned

A model may propose a symbolic invocation name, including inside a generated
plan, but it cannot create executable BEAM code. Directive passes the name to:

```elixir
handle_directive({:invocation, name}, directive_context)
```

The Agent module must resolve it to a trusted function, behaviour module, or
MFA. Unknown names should return an error. Keep authorization in a separate
policy handler; plan mode controls generated plan changes, not permission to
perform effects.

See the runnable [`spectre_agent.exs`](../examples/spectre_agent.exs) for two
questions, a trusted symbolic invocation, and an `on_complete` result in one
flow.
