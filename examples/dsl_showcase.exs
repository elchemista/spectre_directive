defmodule SpectreDirective.Examples.DSLShowcase do
  @moduledoc false

  use Spectre.Directive

  # A module may contain multiple reusable, named directives. This one shows
  # every declaration currently available in the authored DSL.
  directive "greeting" do
    mission "Create and review a greeting"
    context "The greeting is local application data; no external service is needed."
    success "Return a reviewed greeting"
    mode :fixed
    directive_metadata %{owner: :examples, version: 1}

    step "Build greeting" do
      kind :act
      flexibility :locked
      purpose "Create the requested greeting"
      reason "A deterministic local function is sufficient"
      prompt "Use the supplied name and requested style"
      expects "A greeting string"
      done_when "The greeting has been created"
      risk :low
      input %{style: :friendly}
      metadata %{category: :formatting}
      policy :local_computation

      invoke fn context ->
        style = context.step.input.style
        {:complete_step, %{style: style, text: "Hello, #{context.input.name}!"}}
      end
    end

    step "Review greeting" do
      kind :verify
      flexibility :guided
      purpose "Confirm the generated text is ready to return"
      expects "A reviewed greeting"
      done_when "The greeting has passed the local review"
      risk :low
    end

    on_complete fn context ->
      {:ok, %{delivered: context.last_result}}
    end
  end

  # `objective/1` is an alias for `mission/1`; directives may also omit steps
  # and let a reasoner propose the initial plan.
  directive "minimal-autonomous" do
    objective "Demonstrate the smallest generated-plan directive"
    mode :autonomous
  end
end

alias SpectreDirective.Context
alias SpectreDirective.Examples.DSLShowcase

Enum.each(DSLShowcase.__spectre_directives__(), fn blueprint ->
  IO.puts("#{blueprint.name}: #{length(blueprint.plan.steps)} authored step(s)")
end)

reasoner = fn
  %Context{operation: :step, step: %{title: "Review greeting"}} = context ->
    {:complete_step, Map.put(context.last_result, :reviewed?, true)}

  %Context{operation: :mission_review} = context ->
    {:complete_mission, context.last_result}
end

policy_handler = fn :local_computation, _context -> :allow end

{:ok, mission} =
  Spectre.Directive.start_directive(DSLShowcase,
    directive: "greeting",
    input: %{name: "Edsger"},
    reasoner: reasoner,
    policy_handler: policy_handler,
    execution: :auto
  )

{:ok, outcome} = Spectre.Directive.await(mission)
IO.inspect(outcome.result, label: "mission result")
IO.inspect(outcome.completion_result, label: "completion callback result")

:ok = Spectre.Directive.stop(mission)
