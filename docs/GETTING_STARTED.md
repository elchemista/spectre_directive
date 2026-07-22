# Getting started

This guide builds one complete Directive flow without an LLM, external service,
or application framework. It shows where application code takes ownership of
reasoning and effects.

## Install the package

Add Spectre Directive to `mix.exs`:

```elixir
def deps do
  [
    {:spectre_directive, "~> 0.1.0"}
  ]
end
```

Then fetch dependencies with `mix deps.get`.

## Drive a pure loop

The pure API returns data and never invokes application code itself:

```elixir
alias Spectre.Directive
alias Spectre.Directive.Invoker
alias SpectreDirective.Request

{:ok, loop} =
  Directive.new(
    mission: "Greet the supplied person",
    success: "Return one friendly greeting",
    mode: :fixed,
    input: %{name: "Ada"},
    steps: [%{title: "Build the greeting"}]
  )

{:request, %Request{kind: :reason} = request, loop} = Directive.next(loop)

greet = fn context ->
  {:complete_mission, "Hello, #{context.input.name}!"}
end

{:request, %Request{kind: :invoke} = invocation, loop} =
  Directive.respond(loop, request.id, {:invoke, greet})

result = Invoker.call(invocation.target, invocation.context)

{:done, outcome, _loop} =
  Directive.respond(loop, invocation.id, result)

outcome.result
#=> "Hello, Ada!"
```

The host explicitly executes `invocation.target`. A delayed response is safe to
reject because every request carries its request ID, plan version, step ID, and
context revision.

Run the complete version from the repository root:

```bash
mix run examples/pure_loop.exs
```

## Let the optional runtime execute callbacks

For in-process applications, the supervised runtime can execute trusted
reasoners and invocations automatically:

```elixir
reasoner = fn context ->
  case context.operation do
    :mission_review -> {:complete_mission, context.last_result}
  end
end

greet = fn context ->
  {:complete_step, "Hello, #{context.input.name}!"}
end

{:ok, mission} =
  Spectre.Directive.start_mission("Greet the supplied person",
    mode: :fixed,
    input: %{name: "Grace"},
    steps: [%{title: "Build the greeting", invoke: greet}],
    reasoner: reasoner,
    execution: :auto
  )

{:ok, outcome} = Spectre.Directive.await(mission)
:ok = Spectre.Directive.stop(mission)
```

Callbacks run in supervised tasks. Use `execution: :manual` when another
runtime, queue, UI, or persistence layer should resolve every request.

Run the complete automatic example with:

```bash
mix run examples/automatic_runtime.exs
```

## Choose a plan mode

| Mode | Use it when |
| --- | --- |
| `:fixed` | The authored steps are the application contract. |
| `:guided` | A user or application must confirm generated plans and patches. |
| `:autonomous` | A trusted reasoner may apply valid plan changes immediately. |

Plan mode controls plan changes, not authorization. Invocation effects still
belong to the host and can use an explicit policy handler.

## Next steps

- Run the [DSL and Spectre Agent examples](../examples/EXAMPLES.md).
- Read the public API in `Spectre.Directive`.
- Use the authored DSL in the README when missions should be reusable modules.
- Follow the [Spectre Agent integration guide](SPECTRE_AGENT_INTEGRATION.md) for
  questions, repeated replies, event-driven channels, and completion.
- Read `SECURITY.md` before resolving model-generated invocation names.
