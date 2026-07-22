defmodule SpectreDirective.TestAdapter do
  @behaviour Spectre.Directive.Invoker
  @behaviour Spectre.Directive.Reasoner
  @behaviour Spectre.Directive.Policy
  @behaviour Spectre.Directive.RequestHandler

  @impl Spectre.Directive.Invoker
  def invoke(context, opts), do: {:invoked, context.operation, opts}

  @impl Spectre.Directive.Reasoner
  def decide(context, opts), do: {:decided, context.operation, opts}

  @impl Spectre.Directive.Policy
  def authorize(requirement, context, opts),
    do: {:authorized, requirement, context.operation, opts}

  @impl Spectre.Directive.RequestHandler
  def handle_request(request, opts), do: {:handled, request.kind, opts}

  def mfa(context), do: {:mfa, context.operation}
  def mfa(context, extra), do: {:mfa, context.operation, extra}
  def captured(context), do: {:complete_step, context.input}
end

defmodule SpectreDirective.FullDSLDirective do
  use Spectre.Directive

  directive "full" do
    mission("Exercise every DSL field")
    context(%{scope: :test})
    success("All fields compile")
    mode(:adaptive)
    directive_metadata(%{owner: :suite})

    step "Configured" do
      kind(:act)
      flexibility(:agentic)
      purpose("Cover the builder")
      reason("The DSL is public API")
      prompt("Run deterministically")
      expects(:result)
      done_when(:finished)
      risk(:critical)
      input(%{step: 1})
      metadata(%{tag: :all})
      policy(:allowed)
      invoke(&SpectreDirective.TestAdapter.captured/1)
    end

    step("Default")

    on_complete(fn context -> {:complete_mission, context.last_result} end)
  end

  directive :secondary do
    objective("Second mission")
    mode(:strict)
  end
end

defmodule SpectreDirective.DirectUseDSL do
  use SpectreDirective, host: :standalone

  directive "direct" do
    mission("Use the core macro directly")
  end
end

defmodule SpectreDirective.DSLAndAdaptersTest do
  use ExUnit.Case, async: true

  alias SpectreDirective.Context
  alias SpectreDirective.Invocation
  alias SpectreDirective.Loop.Engine
  alias SpectreDirective.Loop.State
  alias SpectreDirective.Request
  alias SpectreDirective.TestAdapter

  setup do
    {:ok, state} = State.new(mission: "Adapter", steps: [%{title: "Step"}])
    {:request, request, _state} = Engine.next(state)
    %{context: request.context, request: request}
  end

  describe "authored DSL" do
    test "compiles every directive and step field into reusable blueprints" do
      assert SpectreDirective.FullDSLDirective.__spectre_directive_host__() == :standalone

      assert [full, secondary] = SpectreDirective.FullDSLDirective.__spectre_directives__()
      assert SpectreDirective.FullDSLDirective.__spectre_directive__() == full
      assert SpectreDirective.FullDSLDirective.__spectre_directive__("full") == full
      assert SpectreDirective.FullDSLDirective.__spectre_directive__(:secondary) == secondary
      assert SpectreDirective.FullDSLDirective.__spectre_directive__("missing") == nil

      assert full.name == "full"
      assert full.mission.goal == "Exercise every DSL field"
      assert full.mission.context == %{scope: :test}
      assert full.mission.success_criteria == "All fields compile"
      assert full.mode == :autonomous
      assert full.metadata == %{owner: :suite}
      assert length(full.plan.steps) == 2

      [configured, default] = full.plan.steps
      assert configured.kind == :act
      assert configured.flexibility == :agentic
      assert configured.purpose == "Cover the builder"
      assert configured.reason == "The DSL is public API"
      assert configured.prompt == "Run deterministically"
      assert configured.expected_output == :result
      assert configured.done_condition == :finished
      assert configured.risk == :critical
      assert configured.input == %{step: 1}
      assert configured.metadata == %{tag: :all}
      assert configured.policy == :allowed
      assert {SpectreDirective.FullDSLDirective, callback} = configured.invoke
      assert is_atom(callback)

      assert default.title == "Default"
      assert default.kind == :investigate
      assert default.risk == :low

      assert secondary.name == "secondary"
      assert secondary.mission.goal == "Second mission"
      assert secondary.mode == :fixed

      assert SpectreDirective.DirectUseDSL.__spectre_directive_host__() == :standalone
      assert SpectreDirective.DirectUseDSL.__spectre_directive__().name == "direct"
    end

    test "compiled anonymous and captured callbacks remain executable", %{context: context} do
      full = SpectreDirective.FullDSLDirective.__spectre_directive__("full")
      configured = hd(full.plan.steps)
      context = %{context | input: :dsl_input, last_result: :stored}

      assert Spectre.Directive.Invoker.call(configured.invoke, context) ==
               {:complete_step, :dsl_input}

      assert Spectre.Directive.Invoker.call(full.on_complete, context) ==
               {:complete_mission, :stored}
    end

    test "compile-time validation rejects malformed directives and use options" do
      assert_compile_error("mission/1 or objective/1 is required", """
      defmodule MissingMissionDirective do
        use Spectre.Directive
        directive "missing" do
          mode :guided
        end
      end
      """)

      assert_compile_error("mode/1 must be one of", """
      defmodule InvalidModeDirective do
        use Spectre.Directive
        directive "mode" do
          mission "Goal"
          mode :wild
        end
      end
      """)

      assert_compile_error("step title must not be empty", """
      defmodule EmptyStepDirective do
        use Spectre.Directive
        directive "step" do
          mission "Goal"
          step "  "
        end
      end
      """)

      assert_compile_error("flexibility/1 must be one of", """
      defmodule InvalidStepDirective do
        use Spectre.Directive
        directive "step" do
          mission "Goal"
          step "Invalid" do
            flexibility :free
            risk :impossible
          end
        end
      end
      """)

      assert_compile_error("use Spectre.Directive expects a keyword list", """
      defmodule InvalidUseDirective do
        use Spectre.Directive, :bad
      end
      """)

      assert_compile_error("invalid Spectre.Directive host", """
      defmodule InvalidHostDirective do
        use Spectre.Directive, host: :unknown
      end
      """)
    end
  end

  describe "reasoner adapter" do
    test "dispatches functions, modules, module options, and invalid targets", %{context: context} do
      one = fn %Context{} = received -> {:one, received.operation} end
      two = fn %Context{} = received, opts -> {:two, received.operation, opts} end

      assert Spectre.Directive.Reasoner.call(one, context, ignored: true) == {:one, :step}
      assert Spectre.Directive.Reasoner.call(two, context, value: 1) == {:two, :step, [value: 1]}

      assert Spectre.Directive.Reasoner.call({TestAdapter, [base: 1]}, context, extra: 2) ==
               {:decided, :step, [base: 1, extra: 2]}

      assert SpectreDirective.Reasoner.call(TestAdapter, context, direct: true) ==
               {:decided, :step, [direct: true]}

      assert SpectreDirective.Reasoner.call("bad target", context) ==
               {:error, {:invalid_reasoner, "bad target"}}
    end
  end

  describe "invoker adapter" do
    test "dispatches functions, modules, option tuples, MFAs, and invalid targets", %{
      context: context
    } do
      function = fn %Context{} = received -> {:function, received.operation} end

      assert Spectre.Directive.Invoker.call(function, context) == {:function, :step}

      assert Spectre.Directive.Invoker.call({TestAdapter, [a: 1]}, context) ==
               {:invoked, :step, [a: 1]}

      assert SpectreDirective.Invoker.call(TestAdapter, context) == {:invoked, :step, []}
      assert SpectreDirective.Invoker.call({TestAdapter, :mfa}, context) == {:mfa, :step}

      assert SpectreDirective.Invoker.call({TestAdapter, :mfa, [:extra]}, context) ==
               {:mfa, :step, :extra}

      assert SpectreDirective.Invoker.call("not executable", context) ==
               {:error, {:invalid_invocation_target, "not executable"}}
    end
  end

  describe "policy and generic request adapters" do
    test "dispatches every policy target shape", %{context: context} do
      two = fn requirement, received -> {:two, requirement, received.operation} end

      three = fn requirement, received, opts ->
        {:three, requirement, received.operation, opts}
      end

      assert Spectre.Directive.Policy.call(two, :read, context) == {:two, :read, :step}

      assert Spectre.Directive.Policy.call(three, :read, context, x: 1) ==
               {:three, :read, :step, [x: 1]}

      assert SpectreDirective.Policy.call({TestAdapter, [base: 1]}, :read, context, x: 2) ==
               {:authorized, :read, :step, [base: 1, x: 2]}

      assert SpectreDirective.Policy.call(TestAdapter, :read, context, direct: true) ==
               {:authorized, :read, :step, [direct: true]}

      assert SpectreDirective.Policy.call("missing policy", :read, context) ==
               {:error, {:invalid_policy_handler, "missing policy"}}
    end

    test "dispatches every generic request handler shape", %{request: request} do
      function = fn received -> {:function, received.kind} end
      assert Spectre.Directive.RequestHandler.call(function, request) == {:function, :reason}

      assert SpectreDirective.RequestHandler.call({TestAdapter, [base: 1]}, request, x: 2) ==
               {:handled, :reason, [base: 1, x: 2]}

      assert SpectreDirective.RequestHandler.call(TestAdapter, request, direct: true) ==
               {:handled, :reason, [direct: true]}

      assert SpectreDirective.RequestHandler.call("invalid", request) ==
               {:error, {:invalid_request_handler, "invalid"}}
    end
  end

  describe "public facade helpers" do
    test "both public namespaces expose pure state, context, and protocol", %{context: context} do
      assert {:ok, %State{}} = Spectre.Directive.new(mission: "Facade")
      assert {:ok, %State{}} = SpectreDirective.new(mission: "Facade")

      assert Spectre.Directive.context_map(context) == Context.to_map(context)
      assert SpectreDirective.context_map(context) == Context.to_map(context)

      assert %{protocol: protocol, context: mapped} = Spectre.Directive.reasoning_input(context)
      assert protocol == Spectre.Directive.protocol()
      assert mapped == Context.to_map(context)
      assert SpectreDirective.reasoning_input(context) == %{protocol: protocol, context: mapped}

      assert %{
               id: SpectreDirective.Runtime.Supervisor,
               start: {SpectreDirective.Runtime.Supervisor, :start_link, [[]]}
             } =
               Spectre.Directive.child_spec([])
    end

    test "invocation constructors accept maps and retain metadata" do
      invocation = Invocation.new(:target, %{policy: :safe, metadata: %{a: 1}})
      assert invocation.policy == :safe
      assert invocation.metadata == %{a: 1}

      assert Invocation.new(invocation, %{metadata: %{b: 2}}).metadata == %{a: 1, b: 2}
    end

    test "request construction copies correlation from context", %{context: context} do
      request = Request.new(:question, context, payload: %{question: "Why?"})
      assert request.kind == :question
      assert request.context == context
      assert request.payload.question == "Why?"
    end
  end

  defp assert_compile_error(message, source) do
    assert_raise ArgumentError, ~r/#{Regex.escape(message)}/, fn ->
      Code.compile_string(source)
    end
  end
end
