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

IO.puts(outcome.result)
