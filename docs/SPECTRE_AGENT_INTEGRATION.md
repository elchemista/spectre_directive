# Integrating with Spectre Agent

Spectre Agent and Spectre Directive own different state:

```text
user/agent transport
        │
        ▼
Spectre turn ──► route, policy, Agent state
        │
        └──────► Directive mission, living plan, questions, outcome
```

Spectre owns one Agent turn, its policy gates, routing, and effects. Directive
owns the longer mission, its versioned plan, accumulated information, pending
request, and terminal outcome. Directive reasoning may use the same Agent
without making Spectre depend on Directive.

There are two valid conversation modes:

| Mode | Start | Answer the user request | Lifetime |
| --- | --- | --- | --- |
| Persisted Agent turns | `start_directive_turn/3` from a route | another ordinary `Spectre.ask/3` with the same conversation id | snapshot per boundary; no waiting pid |
| Live mission | `start_directive/2` | `reply/3` or correlated `respond/3` | one supervised mission process |

Use persisted turns for request/response chat, HTTP, and agent-to-agent
transports where every inbound message already enters Spectre. Use a live
mission for an in-process CLI, LiveView subscription, bot channel, or service
that wants to keep and address a mission pid directly.

## Persist a mission and plan across normal Agent turns

Configure a host-owned Store when using Directive inside an Agent:

```elixir
defmodule MyApp.DirectiveStore do
  @behaviour Spectre.Directive.Store

  @impl true
  def load(key, opts) do
    MyApp.DirectiveSnapshots.load(key, opts)
  end

  @impl true
  def snapshot(key, snapshot, opts) do
    MyApp.DirectiveSnapshots.put(key, snapshot, opts)
  end
end
```

`load/2` returns `{:ok, snapshot}`, `{:ok, nil}`, or `{:error, reason}`.
`snapshot/3` returns `:ok` or `{:error, reason}`. Directive chooses no database
or serialization format.

A `%Spectre.Directive.Snapshot{}` contains the complete pure loop: mission,
living plan, pending correlated request, collected information, trace, and
outcome. `version` identifies the snapshot schema. `revision` begins at one
and advances at every durable user boundary.

A production Store should write atomically and reject a stale revision. It may
treat an exactly identical snapshot as an idempotent retry. Replacing a
terminal mission with a new revision-one mission under the same key is an
application policy. Snapshot data is trusted application data: prefer stable
module/MFA callback targets for durable storage and never decode an untrusted
external Erlang term.

The snapshot also records externally visible turn receipts: stable turn id,
normalized input, typed boundary, and rendered reply. This supports safe reply
replay after ambiguous or delayed duplicate delivery; it does not replace the
Store's revision check.

## Define the Agent

Put `use Spectre.Agent` before `use Spectre.Directive`. Passing `store:` adds
Directive's adapter to Spectre's ordered turn-handler pipeline and
generates `start_directive_turn/3,4` in addition to the existing
`start_directive/1,2` API.

```elixir
defmodule MyApp.ProfileAgent do
  use Spectre.Agent,
    model: MyApp.Models.default()

  use Spectre.Directive,
    store: MyApp.DirectiveStore,
    store_namespace: :profile_missions

  directive "profile" do
    mission "Collect the missing profile fields"
    success "Return a complete profile"
    mode :guided

    on_complete {MyApp.Profiles, :store_from_directive, []}
  end

  flow :profile do
    on :START_PROFILE, regex: ~r/^start profile$/i do
      run :start_profile
    end
  end

  def start_profile(input, spectre_context) do
    start_directive_turn("profile", input, spectre_context)
  end

  def handle_directive({:invocation, "lookup_account"}, _context) do
    {:ok, &MyApp.Accounts.lookup_from_directive/1}
  end

  def handle_directive({:invocation, name}, _context),
    do: {:error, {:unknown_invocation, name}}

  def handle_directive(message, context), do: super(message, context)
end
```

Starting a persisted Directive is an explicit route decision. Merely adding a
Store does not make every unmatched message start a mission. While a stored
mission is active, however, its handler owns subsequent turns for the same
conversation key before normal routing.

The default key is `{store_namespace, conversation_id}`. Without
`store_namespace`, the Agent module is the namespace. Supply a stable
`conversation_id` through trusted Spectre options or input metadata:

```elixir
{:ok, started} =
  Spectre.ask(MyApp.ProfileAgent, "start profile",
    conversation_id: "profile-42",
    turn_id: "message-1"
  )

started.reply_text
#=> "Please confirm the proposed plan."

{:ok, first_question} =
  Spectre.ask(MyApp.ProfileAgent, "yes",
    conversation_id: "profile-42",
    turn_id: "message-2"
  )

first_question.reply_text
#=> "What is your name?"

{:ok, second_question} =
  Spectre.ask(MyApp.ProfileAgent, "Ada",
    conversation_id: "profile-42",
    turn_id: "message-3"
  )

second_question.reply_text
#=> "Which language do you prefer?"

{:ok, completed} =
  Spectre.ask(MyApp.ProfileAgent, "Italian",
    conversation_id: "profile-42",
    turn_id: "message-4"
  )

completed.reply_text
#=> "Mission completed."
```

`conversation_id` selects the mission. `turn_id` identifies one external
message and should come from the HTTP request, queue message, or agent-protocol
envelope when one exists. Retrying the same input with the same `turn_id`
returns the recorded reply without consuming it again. Reusing that id with
different input returns `{:error, {:directive_turn_id_reused, turn_id}}`.
Spectre generates a turn id when it is omitted, which is suitable for a single
local call but cannot identify a later transport retry.

For active conversations, a `Spectre.Session` is recommended because it also
serializes Spectre turns in one process. Stateless module calls remain valid,
but the Store must reject concurrent stale snapshots, especially across nodes.

An already-open Spectre policy always runs before Directive. The first
configured handler that claims a normal turn wins. A trusted host can bypass
every handler for an internal call with `turn_handlers: false`;
do not derive that option from untrusted message content.

## How the Agent asks for more information

Directive decisions stay unchanged. A reasoner asks with `{:ask, question}`
and sees every prior answer in the next `SpectreDirective.Context`:

```elixir
def handle_directive({:reason, %SpectreDirective.Context{operation: :step} = context}, _) do
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
end
```

The temporary Directive runtime executes internal `:reason` and `:invoke`
requests automatically until it reaches another user-owned request or an
outcome. Its internal call to the Spectre Agent explicitly bypasses turn
handlers, so it cannot recursively resume itself.

The built-in text adapter maps:

| Request | Text response |
| --- | --- |
| `:question` | the input text unchanged |
| `:confirmation` | yes/`si`/`sì`/accept/approve, or no/reject/deny |
| `:policy` | allow/approve or deny/reject; other text reaches the policy handler |

A structured UI or agent protocol should avoid text conventions and put the
exact Directive response in input metadata:

```elixir
input = %{
  text: "confirmation button",
  meta: %{spectre_directive_response: :accept}
}

Spectre.ask(MyApp.ProfileAgent, input,
  conversation_id: "profile-42",
  turn_id: "profile-confirmation-message"
)
```

`directive_response` is accepted as a shorter alias. Structured values such as
`{:edit, plan}`, `{:reject, reason}`, or an application policy decision reach
the pending request unchanged.

## Present questions and outcomes

The default `Spectre.Directive.Presenter` produces conservative text. The full
typed request or outcome remains in:

```elixir
result.metadata.spectre_directive.boundary
```

Other useful fields are `key`, `mission_id`, `directive`, `status`,
`plan_version`, and `snapshot_version`. Supply a presenter for localization or
channel-specific wording:

```elixir
defmodule MyApp.DirectivePresenter do
  @behaviour Spectre.Directive.Presenter

  @impl true
  def present({:request, request}, opts),
    do: MyApp.Messages.directive_request(request, opts[:locale])

  def present({:outcome, outcome}, opts),
    do: MyApp.Messages.directive_outcome(outcome, opts[:locale])
end
```

```elixir
use Spectre.Directive,
  store: MyApp.DirectiveStore,
  presenter: MyApp.DirectivePresenter,
  presenter_opts: [locale: "it"]
```

Presenters should be pure: Directive renders the boundary before storing it,
and a failed Store write may cause the same transition to be retried.

## What happens at completion

The reasoner completes the core mission with:

```elixir
{:complete_mission, final_result}
```

If the directive declares `on_complete`, Directive invokes that trusted target
and keeps its result separate:

- `outcome.result` is `final_result`;
- `outcome.completion_result` is the normalized completion callback result;
- `outcome.status` is `:completed`, `:failed`, or `:cancelled`;
- `outcome.reason` explains a failure or cancellation.

The terminal outcome and final plan are written as an inactive snapshot. The
temporary mission process is stopped automatically after every persisted turn,
including completion. A later message under the same conversation key is no
longer claimed by Directive and returns to normal Spectre routing.

`on_complete` runs before the terminal snapshot is acknowledged by the Store.
It may therefore be retried after a storage failure or ambiguous caller
timeout. The same applies to reasoner and invocation callbacks executed after
the previous snapshot and before the next one. Make every external effect in
that interval idempotent, normally using the mission id plus the logical step
or operation as its idempotency key.

A stable `turn_id` prevents replay after the new snapshot is visible. It cannot
atomically couple an external callback side effect to a Store transaction when
the snapshot was not committed.

## Failure and timeout behavior

Store errors, presenter errors, invalid replies, callback crashes, and timeout
failures stop the turn. Spectre does not route the same input elsewhere after
Directive has found an active mission.

`await_timeout` defaults to 25 seconds and should remain lower than Spectre's
`turn_handler_timeout`/`run_timeout`, leaving time to write the snapshot.
Remote cancellation still depends on the Store/model client. The adapter
stops its temporary mission if Spectre terminates the local callback worker.

## Keep a live mission instead

Without `store:`, Directive does not register a turn handler. The existing
generated API starts one supervised mission process:

```elixir
{:ok, mission} =
  MyApp.ProfileAgent.start_directive("profile",
    input: %{account_id: 42}
  )

{:ok, {:request, first}} = Spectre.Directive.await_input(mission)
IO.puts(first.payload.question)

{:ok, {:request, second}} = Spectre.Directive.reply(mission, "Ada")
IO.puts(second.payload.question)

{:ok, {:outcome, outcome}} = Spectre.Directive.reply(mission, "Italian")
:ok = Spectre.Directive.stop(mission)
```

In this mode an answer is deliberately not another `Spectre.ask/3`: the host
already owns and addresses the live mission. `reply/3` refuses internal
`:reason` and `:invoke` requests; the Agent-backed automatic runtime resolves
those itself.

For LiveView, bots, and GenServers, subscribe instead of blocking:

```elixir
{:ok, mission} =
  MyApp.ProfileAgent.start_directive("profile", subscribers: [channel_pid])

receive do
  {:spectre_directive, mission_id, :request, request} ->
    MyApp.Channel.present(mission_id, request)

  {:spectre_directive, mission_id, :outcome, outcome} ->
    MyApp.Channel.complete(mission_id, outcome)

  {:spectre_directive, mission_id, :error, reason} ->
    MyApp.Channel.runtime_error(mission_id, reason)
end
```

Correlate the reply with
`Spectre.Directive.respond(mission_id, request.id, answer)`. Subscribing replays
the current request or outcome, which lets a reconnected channel resume without
guessing.

## Generated tools remain host-owned

A model may propose a symbolic invocation, but it cannot create executable
BEAM code. Directive passes the name to:

```elixir
handle_directive({:invocation, name}, directive_context)
```

The Agent must resolve it to a trusted function, behaviour module, or MFA.
Unknown names should fail closed. Keep authorization in a policy handler;
guided/autonomous mode controls plan changes, not permission to perform an
effect.

Run [`spectre_agent.exs`](../examples/spectre_agent.exs) for the live-mission
mode and [`persistent_spectre_agent.exs`](../examples/persistent_spectre_agent.exs)
for ordinary persisted Spectre turns.
