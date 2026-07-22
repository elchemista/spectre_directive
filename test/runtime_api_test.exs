defmodule SpectreDirective.RuntimeTestAdapter do
  @behaviour Spectre.Directive.Reasoner
  @behaviour Spectre.Directive.Invoker
  @behaviour Spectre.Directive.Policy
  @behaviour Spectre.Directive.RequestHandler

  @impl Spectre.Directive.Reasoner
  def decide(context, opts) do
    send(Keyword.fetch!(opts, :owner), {:module_reasoned, context.operation})
    {:complete_mission, :module_reasoner}
  end

  @impl Spectre.Directive.Invoker
  def invoke(context, opts) do
    send(Keyword.fetch!(opts, :owner), {:module_invoked, context.operation})
    {:complete_mission, :module_invoker}
  end

  @impl Spectre.Directive.Policy
  def authorize(requirement, context, opts) do
    send(Keyword.fetch!(opts, :owner), {:module_policy, requirement, context.operation})
    :allow
  end

  @impl Spectre.Directive.RequestHandler
  def handle_request(request, opts) do
    send(Keyword.fetch!(opts, :owner), {:module_handled, request.kind})
    Keyword.fetch!(opts, :response)
  end
end

defmodule SpectreDirective.RuntimeAuthoredDirective do
  use Spectre.Directive

  directive "runtime" do
    mission("Complete through an authored runtime invocation")
    mode(:fixed)

    step "Finish" do
      invoke(fn context -> {:complete_mission, {:authored, context.input}} end)
    end
  end

  directive "manual" do
    mission("Drive authored steps manually")
    mode(:fixed)
    step("Think")
  end
end

defmodule SpectreDirective.RuntimeAPITest do
  use ExUnit.Case, async: false

  alias SpectreDirective.Context
  alias SpectreDirective.Loop.Engine
  alias SpectreDirective.Loop.State, as: LoopState
  alias SpectreDirective.MissionBlueprint
  alias SpectreDirective.Outcome
  alias SpectreDirective.Request
  alias SpectreDirective.Runtime.MissionMachine
  alias SpectreDirective.Runtime.MissionProcesses
  alias SpectreDirective.Runtime.Notifier
  alias SpectreDirective.Runtime.RequestExecutor
  alias SpectreDirective.Runtime.State, as: RuntimeState

  setup_all do
    assert :ok = SpectreDirective.Runtime.Supervisor.ensure_started()
    assert is_pid(Process.whereis(SpectreDirective.Registry))
    assert is_pid(Process.whereis(SpectreDirective.MissionSupervisor))
    assert is_pid(Process.whereis(SpectreDirective.TaskSupervisor))
    :ok
  end

  describe "public manual runtime API" do
    test "manually drives every step and queries the mission by pid and id" do
      {:ok, mission} =
        Spectre.Directive.start_mission("Manual runtime",
          steps: [%{id: "one", title: "One"}, %{id: "two", title: "Two"}],
          execution: :manual,
          subscribers: [self()],
          input: %{client: 7},
          assigns: %{locale: "it"},
          information: [:initial]
        )

      on_exit(fn -> safe_stop(mission) end)

      assert_receive {:spectre_directive, mission_id, :request,
                      %Request{kind: :reason} = first_request},
                     1_000

      assert {:ok, pulse} = Spectre.Directive.pulse(mission)
      assert pulse.mission_id == mission_id
      assert pulse.current_step.title == "One"
      assert pulse.information_count == 1

      assert {:ok, loop} = Spectre.Directive.state(mission_id)
      assert loop.mission.goal == "Manual runtime"
      assert {:ok, ^first_request} = Spectre.Directive.request(mission)
      assert {:ok, nil} = Spectre.Directive.outcome(mission_id)
      assert {:ok, plan} = Spectre.Directive.plan(mission)
      assert Enum.map(plan.steps, & &1.title) == ["One", "Two"]
      assert {:ok, %Context{} = context} = Spectre.Directive.context(mission_id)
      assert context.input == %{client: 7}
      assert context.assigns == %{locale: "it"}
      assert {:ok, trace} = Spectre.Directive.trace(mission)
      assert Enum.any?(trace, &(&1.type == :started))

      assert {:ok, informed} = Spectre.Directive.inform(mission_id, :live, source: :user)
      assert informed.information_count == 2

      assert_receive {:spectre_directive, ^mission_id, :information, %{content: :live}}, 1_000
      assert_receive {:spectre_directive, ^mission_id, :request, refreshed}, 1_000
      refute refreshed.id == first_request.id

      assert {:ok, assigned} = Spectre.Directive.assign(mission, %{locale: "en", tenant: 9})
      assert assigned.status == :running
      assert_receive {:spectre_directive, ^mission_id, :assigned, %{tenant: 9}}, 1_000
      assert_receive {:spectre_directive, ^mission_id, :request, assigned_request}, 1_000
      refute assigned_request.id == refreshed.id

      assert {:ok, paused} = Spectre.Directive.pause(mission_id)
      assert paused.status == :paused
      assert {:ok, resumed} = Spectre.Directive.resume(mission)
      assert resumed.status == :running

      # respond/2 resolves the currently pending request.
      assert {:ok, next_step} = Spectre.Directive.respond(mission, {:complete_step, :one})
      assert next_step.current_step.title == "Two"
      assert_receive {:spectre_directive, ^mission_id, :request, second_request}, 1_000

      assert {:ok, review} =
               Spectre.Directive.respond(mission_id, second_request.id, {:complete_step, :two})

      assert review.current_step == nil
      assert_receive {:spectre_directive, ^mission_id, :request, review_request}, 1_000

      assert {:ok, completed} =
               Spectre.Directive.respond(
                 mission,
                 review_request.id,
                 {:complete_mission, :manual_done}
               )

      assert completed.status == :completed
      assert_receive {:spectre_directive, ^mission_id, :outcome, %Outcome{} = outcome}, 1_000
      assert outcome.result == :manual_done

      assert {:ok, ^outcome} = Spectre.Directive.await(mission_id, 1_000)
      assert {:ok, ^outcome} = SpectreDirective.await(mission, :infinity)

      assert :ok = Spectre.Directive.subscribe(mission_id, self())
      assert_receive {:spectre_directive, ^mission_id, :outcome, ^outcome}, 1_000

      assert :ok = Spectre.Directive.stop(mission_id)
      assert {:error, :not_found} = Spectre.Directive.pulse(mission_id)
    end

    test "subscribe replays a pending boundary and invalid runtime calls are contained" do
      {:ok, mission} =
        SpectreDirective.start_mission("Subscribe",
          steps: [%{title: "Wait"}],
          execution: :manual
        )

      on_exit(fn -> safe_stop(mission) end)
      assert {:ok, %Request{} = request} = wait_for_request(mission)

      assert :ok = SpectreDirective.subscribe(mission, self())
      assert_receive {:spectre_directive, _mission_id, :request, ^request}, 1_000

      assert {:error, {:invalid_runtime_request, {:subscribe, :not_a_pid}}} =
               :gen_statem.call(mission, {:subscribe, :not_a_pid})

      assert {:error, {:invalid_runtime_request, :unknown}} = :gen_statem.call(mission, :unknown)
      assert {:error, {:invalid_control, :unknown}} = SpectreDirective.control(mission, :unknown)

      assert {:ok, _pulse} = SpectreDirective.control(mission, :cancel)
      assert {:ok, _pulse} = SpectreDirective.control(mission, {:cancel, :again})
    end

    test "validates missing references, response state, timeout, and stop inputs" do
      assert {:error, :not_found} = Spectre.Directive.pulse("missing")
      assert {:error, :not_found} = Spectre.Directive.pulse(:invalid)
      assert {:error, :not_found} = Spectre.Directive.stop("missing")
      assert {:error, :not_found} = Spectre.Directive.stop(:invalid)
      assert {:error, :not_found} = Spectre.Directive.await_input("missing", 0)
      assert {:error, :not_found} = Spectre.Directive.reply("missing", :answer, 0)
      assert {:error, {:invalid_timeout, :bad}} = Spectre.Directive.await("missing", :bad)

      assert {:error, {:invalid_timeout, :bad}} =
               Spectre.Directive.await_input("missing", :bad)

      assert {:error, {:invalid_timeout, :bad}} =
               Spectre.Directive.reply("missing", :answer, :bad)

      {:ok, mission} =
        Spectre.Directive.start_mission("No request",
          steps: [%{title: "Wait"}],
          execution: :manual
        )

      on_exit(fn -> safe_stop(mission) end)
      assert {:error, :timeout} = Spectre.Directive.await(mission, 0)
      assert {:error, :timeout} = Spectre.Directive.await_input(mission, 0)

      assert {:ok, %Request{} = request} = wait_for_request(mission)

      assert {:error, {:not_user_input, :reason}} =
               Spectre.Directive.reply(mission, :not_a_reasoner_response, 0)

      assert {:error, {:stale_response, "old", expected}} =
               Spectre.Directive.respond(mission, "old", :ok)

      assert expected == request.id
      assert {:ok, _pulse} = Spectre.Directive.cancel(mission, :finished)

      assert {:ok, {:outcome, %Outcome{status: :cancelled}}} =
               Spectre.Directive.await_input(mission, 0)

      assert {:error, :no_pending_request} = Spectre.Directive.respond(mission, :late)
      assert {:error, :no_pending_request} = Spectre.Directive.reply(mission, :late, 0)
    end
  end

  describe "runtime construction APIs" do
    test "create accepts string aliases and forwards runtime options" do
      assert {:error, :mission_required} = Spectre.Directive.create(%{})

      assert {:ok, mission} =
               Spectre.Directive.create(%{
                 "objective" => "Created mission",
                 "success_criteria" => "done",
                 "context" => :created,
                 "name" => "created",
                 "mode" => :fixed,
                 "steps" => [%{"title" => "Manual"}],
                 "execution" => :manual,
                 "input" => :input,
                 "assigns" => %{a: 1},
                 "information" => [:seed],
                 "max_iterations" => 5,
                 "metadata" => %{blueprint: true},
                 "mission_metadata" => %{mission: true},
                 "constraints" => [:safe],
                 "risk_boundaries" => [:write]
               })

      on_exit(fn -> safe_stop(mission) end)
      assert {:ok, state} = Spectre.Directive.state(mission)
      assert state.mission.goal == "Created mission"
      assert state.mission.success_criteria == "done"
      assert state.mission.metadata == %{mission: true}
      assert state.metadata == %{blueprint: true}
      assert state.max_iterations == 5
      assert state.working_context.input == :input
      assert state.working_context.assigns == %{a: 1}
      assert {:ok, _pulse} = Spectre.Directive.cancel(mission)
    end

    test "starts existing pure state and mission maps" do
      {:ok, loop} = Engine.new(mission: "Existing loop", steps: [%{title: "Manual"}])
      assert {:ok, loop_mission} = Spectre.Directive.start_loop(loop)
      on_exit(fn -> safe_stop(loop_mission) end)
      assert {:ok, returned} = Spectre.Directive.state(loop_mission)
      assert returned.mission.id == loop.mission.id
      assert {:ok, _pulse} = Spectre.Directive.cancel(loop_mission)

      assert {:ok, map_mission} =
               Spectre.Directive.start_mission(%{goal: "Map mission", context: :map},
                 steps: [%{title: "Manual"}],
                 execution: :manual
               )

      on_exit(fn -> safe_stop(map_mission) end)
      assert {:ok, map_state} = Spectre.Directive.state(map_mission)
      assert map_state.mission.context == :map
      assert {:ok, _pulse} = Spectre.Directive.cancel(map_mission)
    end

    test "starts authored directives and reports invalid module/name errors" do
      assert {:ok, mission} =
               Spectre.Directive.start_directive(SpectreDirective.RuntimeAuthoredDirective,
                 directive: "runtime",
                 input: :payload,
                 execution: :auto
               )

      on_exit(fn -> safe_stop(mission) end)

      assert {:ok, %Outcome{result: {:authored, :payload}}} =
               Spectre.Directive.await(mission, 2_000)

      assert {:error,
              {:directive_not_found, SpectreDirective.RuntimeAuthoredDirective, "missing"}} =
               Spectre.Directive.start_directive(SpectreDirective.RuntimeAuthoredDirective,
                 directive: "missing"
               )

      assert {:error, {:not_a_directive_module, String}} =
               Spectre.Directive.start_directive(String)

      blueprint = MissionBlueprint.from_mission("Blueprint", steps: [%{title: "Manual"}])

      assert {:ok, blueprint_mission} =
               Spectre.Directive.start_directive(blueprint, execution: :manual)

      on_exit(fn -> safe_stop(blueprint_mission) end)
      assert {:ok, _pulse} = Spectre.Directive.cancel(blueprint_mission)
    end

    test "duplicate mission ids are rejected by the registry" do
      opts = [id: "duplicate-runtime-id", steps: [%{title: "Manual"}], execution: :manual]
      assert {:ok, first} = Spectre.Directive.start_mission("First", opts)
      on_exit(fn -> safe_stop(first) end)

      assert {:error, {:already_started, ^first}} =
               Spectre.Directive.start_mission("Second", opts)

      assert {:ok, _pulse} = Spectre.Directive.cancel(first)
    end
  end

  describe "automatic execution" do
    test "functions reason, invoke, revise, and complete without host polling" do
      reasoner = fn
        %Context{operation: :plan}, _opts ->
          {:propose_plan, [%{title: "Collect"}]}

        %Context{operation: :step, information: []}, _opts ->
          {:invoke, fn _context -> {:inform, :collected} end}

        %Context{operation: :step}, _opts ->
          {:complete_step, :step_done}

        %Context{operation: :mission_review}, _opts ->
          {:complete_mission, :auto_done}
      end

      assert {:ok, mission} =
               Spectre.Directive.start_mission("Automatic",
                 mode: :autonomous,
                 reasoner: reasoner,
                 reasoner_opts: [model: :test],
                 execution: :auto,
                 subscribers: [self()]
               )

      on_exit(fn -> safe_stop(mission) end)

      assert {:ok, %Outcome{status: :completed, result: :auto_done}} =
               Spectre.Directive.await(mission, 2_000)

      assert {:ok, state} = Spectre.Directive.state(mission)
      assert state.iteration == 5
      assert Enum.any?(state.working_context.information, &(&1.content == :collected))
      assert_receive {:spectre_directive, _id, :outcome, %Outcome{}}, 1_000
    end

    test "module reasoner, invoker, and policy adapters receive merged options" do
      assert {:ok, reasoned} =
               Spectre.Directive.start_mission("Module reasoner",
                 steps: [%{title: "Reason"}],
                 reasoner: {SpectreDirective.RuntimeTestAdapter, owner: self()},
                 execution: :auto
               )

      on_exit(fn -> safe_stop(reasoned) end)

      assert {:ok, %Outcome{result: :module_reasoner}} =
               Spectre.Directive.await(reasoned, 2_000)

      assert_receive {:module_reasoned, :step}, 1_000

      invocation = {SpectreDirective.RuntimeTestAdapter, owner: self()}
      policy = {SpectreDirective.RuntimeTestAdapter, owner: self()}

      assert {:ok, invoked} =
               Spectre.Directive.start_mission("Module invocation",
                 steps: [
                   %{title: "Invoke", invoke: invocation, policy: :module_policy}
                 ],
                 policy_handler: policy,
                 execution: :auto
               )

      on_exit(fn -> safe_stop(invoked) end)
      assert {:ok, %Outcome{result: :module_invoker}} = Spectre.Directive.await(invoked, 2_000)
      assert_receive {:module_policy, :module_policy, :policy}, 1_000
      assert_receive {:module_invoked, :invoke}, 1_000
    end

    test "generic execution handler can own every request" do
      handler = fn
        %Request{kind: :reason, context: %Context{operation: :step}} ->
          {:complete_mission, :handled}
      end

      assert {:ok, mission} =
               Spectre.Directive.start_mission("Generic handler",
                 steps: [%{title: "Handle"}],
                 execution: {:handler, handler}
               )

      on_exit(fn -> safe_stop(mission) end)
      assert {:ok, %Outcome{result: :handled}} = Spectre.Directive.await(mission, 2_000)
    end

    test "request handler answers questions and guided confirmations" do
      reasoner = fn
        %Context{operation: :plan}, _opts -> {:propose_plan, [%{title: "Ask"}]}
        %Context{operation: :step, information: []}, _opts -> {:ask, "Value?"}
        %Context{operation: :step}, _opts -> {:complete_step, :done}
        %Context{operation: :mission_review}, _opts -> {:complete_mission, :question_done}
      end

      handler = fn
        %Request{kind: :confirmation} -> :accept
        %Request{kind: :question} -> :answer
      end

      assert {:ok, mission} =
               Spectre.Directive.start_mission("Question",
                 mode: :guided,
                 reasoner: reasoner,
                 request_handler: handler,
                 execution: :auto
               )

      on_exit(fn -> safe_stop(mission) end)
      assert {:ok, %Outcome{result: :question_done}} = Spectre.Directive.await(mission, 2_000)

      assert {:ok, state} = Spectre.Directive.state(mission)
      assert Enum.any?(state.working_context.information, &(&1.content == :answer))
      assert state.plan.version == 2
    end

    test "module request handler is supported" do
      handler =
        {SpectreDirective.RuntimeTestAdapter,
         owner: self(), response: {:complete_mission, :module_handler}}

      assert {:ok, mission} =
               Spectre.Directive.start_mission("Module handler",
                 steps: [%{title: "Handle"}],
                 execution: {:handler, handler}
               )

      on_exit(fn -> safe_stop(mission) end)

      assert {:ok, %Outcome{result: :module_handler}} =
               Spectre.Directive.await(mission, 2_000)

      assert_receive {:module_handled, :reason}, 1_000
    end
  end

  describe "worker failure and timeout containment" do
    test "reasoner exceptions and throws become blocker questions" do
      Enum.each(
        [
          fn _context -> raise "model down" end,
          fn _context -> throw(:model_threw) end
        ],
        fn reasoner ->
          assert {:ok, mission} =
                   Spectre.Directive.start_mission("Recover",
                     reasoner: reasoner,
                     execution: :auto,
                     subscribers: [self()]
                   )

          assert_receive {:spectre_directive, mission_id, :request,
                          %Request{kind: :question, payload: %{type: :blocker}}},
                         1_000

          assert Process.alive?(mission)
          assert {:ok, _pulse} = Spectre.Directive.cancel(mission_id, :test_finished)
          safe_stop(mission)
        end
      )
    end

    test "reasoner timeout cancels work and emits a blocker question" do
      reasoner = fn _context ->
        Process.sleep(200)
        {:complete_mission, :late}
      end

      assert {:ok, mission} =
               Spectre.Directive.start_mission("Timeout",
                 reasoner: reasoner,
                 execution: :auto,
                 request_timeout: 10,
                 subscribers: [self()]
               )

      on_exit(fn -> safe_stop(mission) end)

      assert_receive {:spectre_directive, mission_id, :request,
                      %Request{kind: :question} = question},
                     1_000

      assert inspect(question.payload.question) =~ "request_timeout"
      assert {:ok, _pulse} = Spectre.Directive.cancel(mission_id, :done)
    end

    test "invocation exceptions become information and the reasoner can recover" do
      crashing = fn _context -> raise "tool failed" end
      reasoner = fn %Context{operation: :step} -> {:complete_mission, :recovered} end

      assert {:ok, mission} =
               Spectre.Directive.start_mission("Tool crash",
                 steps: [%{title: "Crash", invoke: crashing}],
                 reasoner: reasoner,
                 execution: :auto
               )

      on_exit(fn -> safe_stop(mission) end)
      assert {:ok, %Outcome{result: :recovered}} = Spectre.Directive.await(mission, 2_000)
      assert {:ok, state} = Spectre.Directive.state(mission)

      assert Enum.any?(state.working_context.information, fn information ->
               match?(%{error: {:exception, RuntimeError, "tool failed"}}, information.content)
             end)
    end

    test "policy worker errors leave the request available for manual recovery" do
      policy = fn _requirement, _context -> {:error, :policy_offline} end
      target = fn _context -> {:complete_mission, :allowed_later} end

      assert {:ok, mission} =
               Spectre.Directive.start_mission("Policy recovery",
                 steps: [%{title: "Protected", invoke: target, policy: :approval}],
                 policy_handler: policy,
                 execution: :auto,
                 subscribers: [self()]
               )

      on_exit(fn -> safe_stop(mission) end)

      assert_receive {:spectre_directive, mission_id, :error,
                      {:request_worker_failed, :policy, :policy_offline}},
                     1_000

      assert {:ok, %Request{kind: :policy} = request} = Spectre.Directive.request(mission)
      assert {:ok, _pulse} = Spectre.Directive.respond(mission_id, request.id, :allow)
      assert {:ok, %Outcome{result: :allowed_later}} = Spectre.Directive.await(mission, 2_000)
    end

    test "question handler failures keep the question pending" do
      reasoner = fn _context -> {:ask, "Need a value"} end
      handler = fn _request -> raise "UI unavailable" end

      assert {:ok, mission} =
               Spectre.Directive.start_mission("Question failure",
                 steps: [%{title: "Ask"}],
                 reasoner: reasoner,
                 request_handler: handler,
                 execution: :auto,
                 subscribers: [self()]
               )

      on_exit(fn -> safe_stop(mission) end)

      assert_receive {:spectre_directive, _mission_id, :error,
                      {:request_worker_failed, :question, _reason}},
                     1_000

      assert {:ok, %Request{kind: :question}} = Spectre.Directive.request(mission)
      assert {:ok, _pulse} = Spectre.Directive.cancel(mission)
    end

    test "late worker messages are ignored after reasoning is invalidated" do
      reasoner = fn _context ->
        Process.sleep(100)
        {:complete_mission, :stale}
      end

      assert {:ok, mission} =
               Spectre.Directive.start_mission("Invalidate worker",
                 reasoner: reasoner,
                 execution: :auto,
                 request_timeout: :infinity,
                 subscribers: [self()]
               )

      on_exit(fn -> safe_stop(mission) end)
      assert_receive {:spectre_directive, mission_id, :request, first}, 1_000
      assert {:ok, _pulse} = Spectre.Directive.inform(mission, :new)
      assert_receive {:spectre_directive, ^mission_id, :request, second}, 1_000
      refute first.id == second.id

      send(mission, {make_ref(), {:spectre_worker_result, {:complete_mission, :forged}}})
      Process.sleep(20)
      assert {:ok, nil} = Spectre.Directive.outcome(mission)
      assert {:ok, _pulse} = Spectre.Directive.cancel(mission)
    end
  end

  describe "runtime internals at adapter boundaries" do
    test "runtime state normalizes execution, subscribers, policy aliases, and timeout" do
      {:ok, loop} = Engine.new(mission: "Runtime state")

      automatic =
        RuntimeState.new(loop,
          subscribers: [self(), :not_a_pid],
          execution: :auto,
          policy: :policy,
          request_timeout: :infinity
        )

      assert automatic.subscribers == MapSet.new([self()])
      assert automatic.execution == :auto
      assert automatic.policy_handler == :policy
      assert automatic.request_timeout == :infinity

      assert RuntimeState.new(loop, execution: {:handler, :handler}).execution ==
               {:handler, :handler}

      assert RuntimeState.new(loop, execution: {:handler, nil}).execution == :manual
      assert RuntimeState.new(loop, execution: :invalid).execution == :manual
      assert RuntimeState.new(loop, request_timeout: 0).request_timeout == 30_000
      assert RuntimeState.new(loop, request_timeout: 25).request_timeout == 25
      assert RuntimeState.put_loop(automatic, %{loop | iteration: 2}).loop.iteration == 2
    end

    test "request executor selects and safely executes every adapter", %{test: _test} do
      {:ok, loop} = Engine.new(mission: "Executor", steps: [%{title: "One"}])
      {:request, reason, _loop} = Engine.next(loop)
      invoke = %{reason | kind: :invoke, target: fn _ -> :invoked end}
      policy = %{reason | kind: :policy, payload: %{policy: :safe}}

      assert RequestExecutor.select(RuntimeState.new(loop, execution: :manual), reason) == nil

      assert RequestExecutor.select(
               RuntimeState.new(loop, execution: {:handler, :handler}),
               reason
             ) == {:handler, :handler}

      reasoner = fn _ -> :reasoned end

      assert RequestExecutor.select(RuntimeState.new(loop, []), %{reason | target: reasoner}) ==
               {:reasoner, reasoner}

      assert {:invoker, _target} = RequestExecutor.select(RuntimeState.new(loop, []), invoke)

      assert RequestExecutor.select(RuntimeState.new(loop, policy_handler: :policy), policy) ==
               {:policy, :policy}

      assert RequestExecutor.select(RuntimeState.new(loop, request_handler: :handler), reason) ==
               {:handler, :handler}

      assert RequestExecutor.select(RuntimeState.new(loop, []), %{reason | target: nil}) == nil

      assert RequestExecutor.execute({:reasoner, fn _ -> :reasoned end}, reason) ==
               {:spectre_worker_result, :reasoned}

      assert RequestExecutor.execute({:invoker, fn _ -> :invoked end}, invoke) ==
               {:spectre_worker_result, :invoked}

      assert RequestExecutor.execute({:policy, fn _, _ -> :allow end}, policy) ==
               {:spectre_worker_result, :allow}

      assert RequestExecutor.execute({:handler, fn request -> request.kind end}, reason) ==
               {:spectre_worker_result, :reason}

      assert {:spectre_worker_error, {:exception, RuntimeError, "boom"}} =
               RequestExecutor.execute({:handler, fn _ -> raise "boom" end}, reason)

      assert {:spectre_worker_error, {:throw, :boom}} =
               RequestExecutor.execute({:handler, fn _ -> throw(:boom) end}, reason)
    end

    test "notifier sends each boundary once and replays current state" do
      {:ok, loop} = Engine.new(mission: "Notify")
      runtime = RuntimeState.new(loop, subscribers: [self()])
      changed = LoopState.add_trace(loop, :changed, "Changed")
      runtime = Notifier.put_loop(runtime, changed)
      assert_receive {:spectre_directive, mission_id, :trace, %{type: :changed}}, 1_000

      request = Request.new(:question, LoopState.context(changed), payload: %{question: :why})
      runtime = Notifier.request(runtime, request)
      assert_receive {:spectre_directive, ^mission_id, :request, ^request}, 1_000
      assert Notifier.request(runtime, request) == runtime
      refute_receive {:spectre_directive, ^mission_id, :request, ^request}, 20

      loop_with_request = %{changed | pending_request: request}
      assert :ok = Notifier.current_boundary(self(), loop_with_request)
      assert_receive {:spectre_directive, ^mission_id, :request, ^request}, 1_000

      outcome = Outcome.new(mission_id, :completed, result: :ok)
      runtime = Notifier.outcome(runtime, outcome)
      assert_receive {:spectre_directive, ^mission_id, :outcome, ^outcome}, 1_000
      assert Notifier.outcome(runtime, outcome) == runtime

      assert :ok = Notifier.current_boundary(self(), %{changed | outcome: outcome})
      assert_receive {:spectre_directive, ^mission_id, :outcome, ^outcome}, 1_000
      assert :ok = Notifier.current_boundary(self(), changed)
      assert :ok = Notifier.event(runtime, :custom, :payload)
      assert_receive {:spectre_directive, ^mission_id, :custom, :payload}, 1_000
    end

    test "supervisor and mission child specifications are stable" do
      supervisor_spec = SpectreDirective.child_spec([])
      assert supervisor_spec.type == :supervisor
      assert {:error, {:already_started, _pid}} = SpectreDirective.start_link()
      assert :ok = SpectreDirective.Runtime.Supervisor.ensure_started()

      blueprint = MissionBlueprint.from_mission("Spec")
      spec = MissionMachine.child_spec(blueprint: blueprint)
      assert spec.restart == :temporary
      assert spec.type == :worker
      assert spec.id == {MissionMachine, blueprint.mission.id}

      assert_raise ArgumentError, ~r/requires :loop or :blueprint/, fn ->
        MissionMachine.child_spec([])
      end
    end

    test "mission process helpers reject dead and malformed references" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, :normal}, 1_000

      assert {:error, :not_found} = MissionProcesses.state(dead)
      assert {:error, :not_found} = MissionProcesses.state({:bad, :ref})
      assert {:error, :not_found} = MissionProcesses.stop(dead)
    end
  end

  defp wait_for_request(mission, attempts \\ 50)
  defp wait_for_request(_mission, 0), do: {:error, :timeout}

  defp wait_for_request(mission, attempts) do
    case Spectre.Directive.request(mission) do
      {:ok, %Request{} = request} ->
        {:ok, request}

      {:ok, nil} ->
        Process.sleep(10)
        wait_for_request(mission, attempts - 1)

      error ->
        error
    end
  end

  defp safe_stop(mission) when is_pid(mission) do
    if Process.alive?(mission), do: Spectre.Directive.stop(mission), else: :ok
  end
end
