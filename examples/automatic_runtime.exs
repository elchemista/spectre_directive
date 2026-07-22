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
IO.puts(outcome.result)

:ok = Spectre.Directive.stop(mission)
