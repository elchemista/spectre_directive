defmodule SpectreDirective.TestAgents.PolicyAgent do
  use Spectre.Agent
  use Spectre.Directive

  alias SpectreDirective.Context
  alias SpectreDirective.Information

  directive "policy" do
    mission("Execute a policy-controlled action and recover when approval is unavailable")
    mode(:autonomous)
  end

  @impl Spectre.Directive.Handler
  def handle_directive({:reason, %Context{operation: :plan}}, _spectre_context) do
    {:propose_plan,
     [
       %{
         id: "restricted",
         title: "Run restricted action",
         invoke: "restricted_tool",
         policy: :external_write
       }
     ]}
  end

  def handle_directive({:reason, %Context{operation: :step} = context}, _spectre_context) do
    cond do
      answer = answer(context) -> {:complete_step, {:policy_fallback, answer}}
      policy_denied?(context) -> {:blocked, :policy_denied_requires_user_direction}
      true -> {:complete_step, :policy_resolved_without_action}
    end
  end

  def handle_directive(
        {:reason, %Context{operation: :mission_review}},
        _spectre_context
      ) do
    {:complete_mission, :policy_flow_done}
  end

  def handle_directive({:invocation, "restricted_tool"}, _context) do
    fn context ->
      send(context.assigns.test_pid, {:restricted_tool_called, context.mission.id})
      {:complete_step, :restricted_tool_done}
    end
  end

  def handle_directive(message, context), do: super(message, context)

  defp policy_denied?(%Context{} = context) do
    Enum.any?(context.information, fn
      %Information{content: %{policy: :external_write, decision: decision}} ->
        decision not in [:allow, :approved, :accept, true, {:ok, :approved}]

      _information ->
        false
    end)
  end

  defp answer(%Context{} = context) do
    Enum.find_value(context.information, fn
      %Information{source: {:answer, _request_id}, content: content} -> content
      _information -> nil
    end)
  end
end

defmodule SpectreDirective.TestAgents.InteractiveAgent do
  use Spectre.Agent
  use Spectre.Directive

  alias SpectreDirective.Context
  alias SpectreDirective.Information

  directive "interactive" do
    mission("Build a user-approved plan and collect the missing client identifier")
    mode(:guided)
  end

  @impl Spectre.Directive.Handler
  def handle_directive({:reason, %Context{operation: :plan} = context}, _spectre_context) do
    title =
      if rejected_plan?(context),
        do: "Safe alternative",
        else: "Collect client identifier"

    {:propose_plan, [%{id: "collect-client", title: title}]}
  end

  def handle_directive({:reason, %Context{operation: :step} = context}, _spectre_context) do
    case answer(context) do
      nil -> {:ask, "Which client identifier should be used?"}
      answer -> {:complete_step, {:client_selected, answer}}
    end
  end

  def handle_directive(
        {:reason, %Context{operation: :mission_review}},
        _spectre_context
      ) do
    {:complete_mission, :interactive_flow_done}
  end

  def handle_directive(message, context), do: super(message, context)

  defp rejected_plan?(%Context{} = context) do
    Enum.any?(context.information, fn
      %Information{content: %{proposal_rejected: _reason}} -> true
      _information -> false
    end)
  end

  defp answer(%Context{} = context) do
    Enum.find_value(context.information, fn
      %Information{source: {:answer, _request_id}, content: content} -> content
      _information -> nil
    end)
  end
end

defmodule SpectreDirective.TestAgents.RecoveryAgent do
  use Spectre.Agent
  use Spectre.Directive

  alias SpectreDirective.Context
  alias SpectreDirective.Information

  directive "recovery" do
    mission("Recover a plan after its primary tool fails")
    mode(:autonomous)
  end

  @impl Spectre.Directive.Handler
  def handle_directive({:reason, %Context{operation: :plan}}, _spectre_context) do
    {:propose_plan, [%{id: "fragile", title: "Run fragile tool", invoke: "fragile_tool"}]}
  end

  def handle_directive({:reason, %Context{operation: :step} = context}, _spectre_context) do
    cond do
      answer = answer(context) ->
        {:complete_step, {:continued_with_user_answer, answer}}

      error = invocation_error(context) ->
        patch = [
          {:skip, context.step.id, {:recovered_from, error}},
          {:add, %{id: "fallback", title: "Run fallback tool", invoke: "fallback_tool"}}
        ]

        {:propose_patch, patch, %{recovery_trigger: error}}

      true ->
        {:complete_step, :fragile_tool_returned_information}
    end
  end

  def handle_directive(
        {:reason, %Context{operation: :mission_review} = context},
        _spectre_context
      ) do
    {:complete_mission, {:recovery_flow_done, context.assigns.failure_mode}}
  end

  def handle_directive({:invocation, "fragile_tool"}, _context), do: &run_fragile/1

  def handle_directive({:invocation, "fallback_tool"}, _context) do
    fn context ->
      mode = context.assigns.failure_mode
      send(context.assigns.test_pid, {:fallback_tool_called, mode})
      {:complete_step, {:recovered, mode}}
    end
  end

  def handle_directive(message, context), do: super(message, context)

  defp run_fragile(%Context{} = context) do
    mode = context.assigns.failure_mode
    send(context.assigns.test_pid, {:fragile_tool_called, mode})
    fragile_result(mode)
  end

  defp fragile_result(:success), do: {:complete_step, :fragile_tool_done}
  defp fragile_result(:error), do: {:error, :fragile_error}
  defp fragile_result(:raise), do: raise("fragile tool raised")
  defp fragile_result(:throw), do: throw(:fragile_throw)
  defp fragile_result(:exit), do: exit(:fragile_exit)
  defp fragile_result(:kill), do: Process.exit(self(), :kill)
  defp fragile_result(:timeout), do: Process.sleep(2_000)
  defp fragile_result(:ask), do: {:ask, "May the fragile operation continue?"}
  defp fragile_result(:complete_mission), do: {:complete_mission, :tool_completed_mission}

  defp invocation_error(%Context{} = context) do
    Enum.find_value(context.information, fn
      %Information{content: %{error: error}, step_id: step_id}
      when step_id == context.step.id ->
        error

      _information ->
        nil
    end)
  end

  defp answer(%Context{} = context) do
    Enum.find_value(context.information, fn
      %Information{source: {:answer, _request_id}, content: content} -> content
      _information -> nil
    end)
  end
end

defmodule SpectreDirective.TestAgents.InterruptionAgent do
  use Spectre.Agent
  use Spectre.Directive

  alias SpectreDirective.Context
  alias SpectreDirective.Information

  directive "interruption" do
    mission("Replace stale reasoning when the application supplies newer information")
    mode(:autonomous)
  end

  @impl Spectre.Directive.Handler
  def handle_directive({:reason, %Context{operation: :plan} = context}, _spectre_context) do
    title =
      cond do
        informed?(context) -> "Plan from fresh information"
        context.assigns[:version] == 2 -> "Plan from fresh assigns"
        context.assigns[:resumed?] -> "Plan after resume"
        true -> slow_stale_plan(context)
      end

    {:propose_plan, [%{id: "finish", title: title, invoke: "finish"}]}
  end

  def handle_directive(
        {:reason, %Context{operation: :mission_review}},
        _spectre_context
      ) do
    {:complete_mission, :interruption_flow_done}
  end

  def handle_directive({:invocation, "finish"}, _context) do
    fn context -> {:complete_step, {:used_plan, context.step.title}} end
  end

  def handle_directive(message, context), do: super(message, context)

  defp slow_stale_plan(%Context{} = context) do
    send(context.assigns.test_pid, {:spectre_reasoning_started, context.mission.id})
    Process.sleep(context.assigns[:delay] || 500)
    "Stale plan"
  end

  defp informed?(%Context{} = context) do
    Enum.any?(context.information, fn
      %Information{content: :urgent_update} -> true
      _information -> false
    end)
  end
end

defmodule SpectreDirective.TestAgents.CompletionAgent do
  use Spectre.Agent
  use Spectre.Directive

  alias SpectreDirective.Context

  directive "completion" do
    mission("Finish a mission and run the application-owned completion callback")
    mode(:fixed)
    step("Prepare final result")
  end

  @impl Spectre.Directive.Handler
  def handle_directive({:reason, %Context{operation: :step}}, _spectre_context),
    do: {:complete_step, :prepared}

  def handle_directive(
        {:reason, %Context{operation: :mission_review}},
        _spectre_context
      ),
      do: {:complete_mission, :core_result}

  def handle_directive(message, context), do: super(message, context)
end

defmodule SpectreDirective.TestAgents.ModelAgent do
  use Spectre.Agent
  use Spectre.Directive

  directive "model" do
    mission("Exercise the default Spectre model boundary")
    mode(:autonomous)
  end

  @impl Spectre.Directive.Handler
  def handle_directive({:invocation, "finish"}, _context) do
    fn _context -> {:complete_step, :model_tool_done} end
  end

  def handle_directive(message, context), do: super(message, context)
end

defmodule SpectreDirective.SpectreAgentScenariosTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias SpectreDirective.Invocation
  alias SpectreDirective.Outcome
  alias SpectreDirective.Request
  alias SpectreDirective.TestAgents.CompletionAgent
  alias SpectreDirective.TestAgents.InteractiveAgent
  alias SpectreDirective.TestAgents.InterruptionAgent
  alias SpectreDirective.TestAgents.ModelAgent
  alias SpectreDirective.TestAgents.PolicyAgent
  alias SpectreDirective.TestAgents.RecoveryAgent

  setup_all do
    SpectreDirective.Runtime.Supervisor.ensure_started()
    :ok
  end

  describe "policy-controlled Spectre Agent plans" do
    test "an allowed policy executes the resolved tool and completes the plan" do
      test_pid = self()

      policy = fn requirement, context ->
        send(test_pid, {:policy_checked, requirement, context.step.id})
        :allow
      end

      mission =
        start_agent(PolicyAgent, "policy",
          assigns: %{test_pid: test_pid},
          policy_handler: policy
        )

      assert {:ok, %Outcome{status: :completed, result: :policy_flow_done}} =
               Spectre.Directive.await(mission, 3_000)

      assert_receive {:policy_checked, :external_write, "restricted"}
      assert_receive {:restricted_tool_called, _mission_id}

      assert {:ok, state} = Spectre.Directive.state(mission)

      assert [%{id: "restricted", status: :completed, result: :restricted_tool_done}] =
               state.plan.steps

      assert Enum.any?(state.working_context.information, fn information ->
               information.content == %{policy: :external_write, decision: :allow}
             end)

      assert_trace(state, :step_completed)
    end

    test "approved wrapped policy responses are treated as allowed" do
      mission =
        start_agent(PolicyAgent, "policy",
          assigns: %{test_pid: self()},
          policy_handler: fn _requirement, _context -> {:ok, :approved} end
        )

      assert {:ok, %Outcome{status: :completed}} = Spectre.Directive.await(mission, 3_000)
      assert_receive {:restricted_tool_called, _mission_id}
    end

    test "a denied policy interrupts the step and the Agent asks the user for a fallback" do
      mission =
        start_agent(PolicyAgent, "policy",
          assigns: %{test_pid: self()},
          policy_handler: fn _requirement, _context -> :deny end
        )

      question = wait_for_request(mission, :question)
      assert question.payload.question == :policy_denied_requires_user_direction
      refute_receive {:restricted_tool_called, _mission_id}, 50

      assert {:ok, _pulse} =
               Spectre.Directive.respond(mission, question.id, "use the read-only fallback")

      assert {:ok, %Outcome{status: :completed, result: :policy_flow_done}} =
               Spectre.Directive.await(mission, 3_000)

      assert {:ok, state} = Spectre.Directive.state(mission)
      assert [step] = state.plan.steps
      assert step.result == {:policy_fallback, "use the read-only fallback"}
      assert_trace(state, :policy_denied)
      assert_trace(state, :answered)
    end

    test "without a policy handler the application can approve the pending request manually" do
      mission = start_agent(PolicyAgent, "policy", assigns: %{test_pid: self()})
      request = wait_for_request(mission, :policy)

      assert request.payload.policy == :external_write
      assert request.payload.purpose == :authored_step
      assert {:ok, _pulse} = Spectre.Directive.respond(mission, request.id, :allow)

      assert {:ok, %Outcome{status: :completed}} = Spectre.Directive.await(mission, 3_000)
      assert_receive {:restricted_tool_called, _mission_id}
    end

    test "a crashing policy worker leaves the correlated request available for manual recovery" do
      mission =
        start_agent(PolicyAgent, "policy",
          assigns: %{test_pid: self()},
          policy_handler: fn _requirement, _context -> raise "policy backend crashed" end,
          subscribers: [self()]
        )

      request = wait_for_request(mission, :policy)

      assert_receive {:spectre_directive, mission_id, :error,
                      {:request_worker_failed, :policy,
                       {:exception, RuntimeError, "policy backend crashed"}}},
                     2_000

      assert mission_id == request.mission_id
      assert {:ok, %Request{id: request_id, kind: :policy}} = Spectre.Directive.request(mission)
      assert request_id == request.id

      assert {:ok, _pulse} = Spectre.Directive.respond(mission, request.id, :allow)
      assert {:ok, %Outcome{status: :completed}} = Spectre.Directive.await(mission, 3_000)
      assert_receive {:restricted_tool_called, _mission_id}
    end

    test "a timed-out policy worker can be denied manually without running the tool" do
      mission =
        start_agent(PolicyAgent, "policy",
          assigns: %{test_pid: self()},
          policy_handler: fn _requirement, _context -> Process.sleep(2_000) end,
          request_timeout: 500,
          subscribers: [self()]
        )

      request = wait_for_request(mission, :policy)

      assert_receive {:spectre_directive, _mission_id, :error,
                      {:request_worker_failed, :policy, {:request_timeout, 500}}},
                     2_000

      assert {:ok, _pulse} = Spectre.Directive.respond(mission, request.id, :deny)
      question = wait_for_request(mission, :question)
      assert {:ok, _pulse} = Spectre.Directive.respond(mission, question.id, :skip_action)

      assert {:ok, %Outcome{status: :completed}} = Spectre.Directive.await(mission, 3_000)
      refute_receive {:restricted_tool_called, _mission_id}, 50
    end

    test "an opaque non-approval response is recorded as a denial" do
      mission =
        start_agent(PolicyAgent, "policy",
          assigns: %{test_pid: self()},
          policy_handler: fn _requirement, _context -> {:review, :security_team} end
        )

      question = wait_for_request(mission, :question)
      assert {:ok, state} = Spectre.Directive.state(mission)

      assert Enum.any?(state.working_context.information, fn information ->
               information.content == %{
                 policy: :external_write,
                 decision: {:review, :security_team}
               }
             end)

      assert {:ok, _pulse} = Spectre.Directive.cancel(mission, :test_finished)
      assert {:ok, %Outcome{status: :cancelled}} = Spectre.Directive.await(mission, 1_000)
      assert question.kind == :question
    end
  end

  describe "questions, confirmations, and user replies through a Spectre Agent" do
    test "the user accepts a generated plan, answers the Agent, and completes the mission" do
      mission = start_agent(InteractiveAgent, "interactive")

      confirmation = wait_for_request(mission, :confirmation)
      assert confirmation.payload.proposal_type == :plan
      assert {:ok, _pulse} = Spectre.Directive.respond(mission, confirmation.id, :accept)

      question = wait_for_request(mission, :question)
      assert question.payload.question == "Which client identifier should be used?"
      assert {:ok, _pulse} = Spectre.Directive.respond(mission, question.id, "client-42")

      assert {:ok, %Outcome{status: :completed, result: :interactive_flow_done}} =
               Spectre.Directive.await(mission, 3_000)

      assert {:ok, state} = Spectre.Directive.state(mission)
      assert [step] = state.plan.steps
      assert step.result == {:client_selected, "client-42"}
      assert_trace(state, :proposal_accepted)
      assert_trace(state, :answered)
    end

    test "an invalid confirmation keeps the same request until the user edits the plan" do
      mission = start_agent(InteractiveAgent, "interactive")
      confirmation = wait_for_request(mission, :confirmation)

      assert {:error, {:invalid_confirmation, :maybe}} =
               Spectre.Directive.respond(mission, confirmation.id, :maybe)

      assert {:ok, %Request{id: same_id, kind: :confirmation}} =
               Spectre.Directive.request(mission)

      assert same_id == confirmation.id

      edited = [%{id: "edited", title: "User-edited client step"}]
      assert {:ok, _pulse} = Spectre.Directive.respond(mission, confirmation.id, {:edit, edited})

      question = wait_for_request(mission, :question)
      assert {:ok, _pulse} = Spectre.Directive.respond(mission, question.id, "edited-client")
      assert {:ok, %Outcome{status: :completed}} = Spectre.Directive.await(mission, 3_000)

      assert {:ok, plan} = Spectre.Directive.plan(mission)
      assert [%{id: "edited", title: "User-edited client step", status: :completed}] = plan.steps
    end

    test "a rejected plan becomes information and the Agent proposes a safer replacement" do
      mission = start_agent(InteractiveAgent, "interactive")
      first = wait_for_request(mission, :confirmation)

      assert {:ok, _pulse} =
               Spectre.Directive.respond(mission, first.id, {:reject, :unsafe_scope})

      second = wait_for_request_except(mission, :confirmation, first.id)
      assert [%{title: "Safe alternative"}] = second.payload.proposal.steps
      assert {:ok, _pulse} = Spectre.Directive.respond(mission, second.id, :approved)

      question = wait_for_request(mission, :question)
      assert {:ok, _pulse} = Spectre.Directive.respond(mission, question.id, "safe-client")
      assert {:ok, %Outcome{status: :completed}} = Spectre.Directive.await(mission, 3_000)

      assert {:ok, state} = Spectre.Directive.state(mission)
      assert_trace(state, :proposal_rejected)
      assert hd(state.plan.steps).title == "Safe alternative"
    end

    test "a generic request handler can represent the user for both confirmation and question" do
      test_pid = self()

      handler = fn request ->
        send(test_pid, {:application_handled, request.kind, request.id})

        case request.kind do
          :confirmation -> :accept
          :question -> "automatic-client"
        end
      end

      mission =
        start_agent(InteractiveAgent, "interactive", request_handler: handler)

      assert {:ok, %Outcome{status: :completed}} = Spectre.Directive.await(mission, 3_000)
      assert_receive {:application_handled, :confirmation, _request_id}
      assert_receive {:application_handled, :question, _request_id}

      assert {:ok, state} = Spectre.Directive.state(mission)
      assert hd(state.plan.steps).result == {:client_selected, "automatic-client"}
    end

    test "a crashing confirmation handler emits an error and permits a manual reply" do
      handler = fn
        %Request{kind: :confirmation} -> raise "confirmation UI crashed"
        %Request{kind: :question} -> "recovered-client"
      end

      mission =
        start_agent(InteractiveAgent, "interactive",
          request_handler: handler,
          subscribers: [self()]
        )

      confirmation = wait_for_request(mission, :confirmation)

      assert_receive {:spectre_directive, _mission_id, :error,
                      {:request_worker_failed, :confirmation,
                       {:exception, RuntimeError, "confirmation UI crashed"}}},
                     2_000

      assert {:ok, _pulse} = Spectre.Directive.respond(mission, confirmation.id, :accept)
      assert {:ok, %Outcome{status: :completed}} = Spectre.Directive.await(mission, 3_000)
    end

    test "a timed-out question handler leaves the question available for the real user" do
      handler = fn
        %Request{kind: :confirmation} -> :accept
        %Request{kind: :question} -> Process.sleep(2_000)
      end

      mission =
        start_agent(InteractiveAgent, "interactive",
          request_handler: handler,
          request_timeout: 500,
          subscribers: [self()]
        )

      question = wait_for_request(mission, :question)

      assert_receive {:spectre_directive, _mission_id, :error,
                      {:request_worker_failed, :question, {:request_timeout, 500}}},
                     2_000

      assert {:ok, %Request{id: request_id, kind: :question}} =
               Spectre.Directive.request(mission)

      assert request_id == question.id
      assert {:ok, _pulse} = Spectre.Directive.respond(mission, question.id, "human-client")
      assert {:ok, %Outcome{status: :completed}} = Spectre.Directive.await(mission, 3_000)
    end

    test "application information can be added while a user question remains correlated" do
      mission = start_agent(InteractiveAgent, "interactive")
      confirmation = wait_for_request(mission, :confirmation)
      assert {:ok, _pulse} = Spectre.Directive.respond(mission, confirmation.id, :accept)

      question = wait_for_request(mission, :question)
      assert {:ok, _pulse} = Spectre.Directive.inform(mission, :background_fact, source: :app)
      assert {:ok, %Request{id: same_id}} = Spectre.Directive.request(mission)
      assert same_id == question.id

      assert {:ok, _pulse} = Spectre.Directive.respond(mission, question.id, "client-with-fact")
      assert {:ok, %Outcome{status: :completed}} = Spectre.Directive.await(mission, 3_000)

      assert {:ok, state} = Spectre.Directive.state(mission)
      assert Enum.any?(state.working_context.information, &(&1.content == :background_fact))
    end
  end

  describe "tool failures and self-correcting plan patches" do
    for mode <- [:error, :raise, :throw, :exit, :kill] do
      @mode mode

      test "the Agent patches the plan after #{mode} from its primary tool" do
        mode = @mode

        mission =
          start_agent(RecoveryAgent, "recovery", assigns: %{test_pid: self(), failure_mode: mode})

        assert {:ok,
                %Outcome{
                  status: :completed,
                  result: {:recovery_flow_done, ^mode}
                }} = Spectre.Directive.await(mission, 4_000)

        assert_receive {:fragile_tool_called, ^mode}
        assert_receive {:fallback_tool_called, ^mode}

        assert {:ok, state} = Spectre.Directive.state(mission)
        assert state.plan.version == 3

        assert [
                 %{id: "fragile", status: :skipped},
                 %{id: "fallback", status: :completed, result: {:recovered, ^mode}}
               ] = state.plan.steps

        assert Enum.any?(state.working_context.information, fn
                 %{content: %{error: _error}, step_id: "fragile"} -> true
                 _information -> false
               end)

        assert_trace(state, :plan_patched)
        assert_trace(state, :invocation_result)
      end
    end

    test "an invocation timeout is converted to information and recovered with a fallback step" do
      mission =
        start_agent(RecoveryAgent, "recovery",
          assigns: %{test_pid: self(), failure_mode: :timeout},
          request_timeout: 500
        )

      assert {:ok,
              %Outcome{
                status: :completed,
                result: {:recovery_flow_done, :timeout}
              }} = Spectre.Directive.await(mission, 4_000)

      assert_receive {:fragile_tool_called, :timeout}
      assert_receive {:fallback_tool_called, :timeout}

      assert {:ok, state} = Spectre.Directive.state(mission)

      assert Enum.any?(state.working_context.information, fn
               %{content: %{error: {:request_timeout, 500}}} -> true
               _information -> false
             end)

      assert Enum.map(state.plan.steps, &{&1.id, &1.status}) == [
               {"fragile", :skipped},
               {"fallback", :completed}
             ]
    end

    test "the primary tool succeeds without an unnecessary plan correction" do
      mission =
        start_agent(RecoveryAgent, "recovery",
          assigns: %{test_pid: self(), failure_mode: :success}
        )

      assert {:ok,
              %Outcome{
                status: :completed,
                result: {:recovery_flow_done, :success}
              }} = Spectre.Directive.await(mission, 3_000)

      assert_receive {:fragile_tool_called, :success}
      refute_receive {:fallback_tool_called, :success}, 50

      assert {:ok, state} = Spectre.Directive.state(mission)
      assert state.plan.version == 2

      assert [%{id: "fragile", status: :completed, result: :fragile_tool_done}] =
               state.plan.steps

      refute Enum.any?(state.trace, &(&1.type == :plan_patched))
    end

    test "a tool can pause itself for user input and continue the same step after the reply" do
      mission =
        start_agent(RecoveryAgent, "recovery", assigns: %{test_pid: self(), failure_mode: :ask})

      question = wait_for_request(mission, :question)
      assert question.payload.question == "May the fragile operation continue?"
      assert {:ok, _pulse} = Spectre.Directive.respond(mission, question.id, :approved_by_user)

      assert {:ok, %Outcome{status: :completed}} = Spectre.Directive.await(mission, 3_000)

      assert {:ok, state} = Spectre.Directive.state(mission)

      assert [
               %{
                 id: "fragile",
                 status: :completed,
                 result: {:continued_with_user_answer, :approved_by_user}
               }
             ] = state.plan.steps

      assert state.plan.version == 2
    end

    test "a trusted tool can complete the whole mission directly" do
      mission =
        start_agent(RecoveryAgent, "recovery",
          assigns: %{test_pid: self(), failure_mode: :complete_mission}
        )

      assert {:ok, %Outcome{status: :completed, result: :tool_completed_mission}} =
               Spectre.Directive.await(mission, 3_000)

      assert_receive {:fragile_tool_called, :complete_mission}
      assert {:ok, state} = Spectre.Directive.state(mission)
      assert_trace(state, :completed)
    end
  end

  describe "in-flight Spectre reasoning interruption and runtime controls" do
    test "new application information cancels stale reasoning and drives a fresh Agent turn" do
      mission =
        start_agent(InterruptionAgent, "interruption", assigns: %{test_pid: self(), delay: 2_000})

      assert_receive {:spectre_reasoning_started, mission_id}, 2_000
      assert {:ok, _pulse} = Spectre.Directive.inform(mission, :urgent_update, source: :browser)

      assert {:ok, %Outcome{status: :completed, result: :interruption_flow_done}} =
               Spectre.Directive.await(mission, 3_000)

      assert {:ok, state} = Spectre.Directive.state(mission)
      assert state.mission.id == mission_id
      assert [%{title: "Plan from fresh information", status: :completed}] = state.plan.steps
      refute Enum.any?(state.plan.steps, &(&1.title == "Stale plan"))
      assert_trace(state, :request_invalidated)
    end

    test "new application assigns invalidate the old turn and reach the replacement context" do
      mission =
        start_agent(InterruptionAgent, "interruption",
          assigns: %{test_pid: self(), delay: 2_000, version: 1}
        )

      assert_receive {:spectre_reasoning_started, _mission_id}, 2_000
      assert {:ok, _pulse} = Spectre.Directive.assign(mission, %{version: 2})

      assert {:ok, %Outcome{status: :completed}} = Spectre.Directive.await(mission, 3_000)

      assert {:ok, state} = Spectre.Directive.state(mission)
      assert state.working_context.assigns.version == 2
      assert [%{title: "Plan from fresh assigns", status: :completed}] = state.plan.steps
      assert_trace(state, :assigned)
      assert_trace(state, :request_invalidated)
    end

    test "pausing kills in-flight reasoning and resume starts from application-updated state" do
      mission =
        start_agent(InterruptionAgent, "interruption", assigns: %{test_pid: self(), delay: 2_000})

      assert_receive {:spectre_reasoning_started, _mission_id}, 2_000
      assert {:ok, %{status: :paused}} = Spectre.Directive.pause(mission)
      assert {:ok, state} = Spectre.Directive.state(mission)
      assert state.status == :paused
      assert state.plan.steps == []

      assert {:ok, %{status: :paused}} =
               Spectre.Directive.assign(mission, %{resumed?: true, delay: 0})

      assert {:ok, %{status: :running}} = Spectre.Directive.resume(mission)
      assert {:ok, %Outcome{status: :completed}} = Spectre.Directive.await(mission, 3_000)

      assert {:ok, state} = Spectre.Directive.state(mission)
      assert [%{title: "Plan after resume", status: :completed}] = state.plan.steps
      assert_trace(state, :paused)
      assert_trace(state, :resumed)
    end

    test "cancelling during an Agent turn terminates work and produces one terminal outcome" do
      mission =
        start_agent(InterruptionAgent, "interruption",
          assigns: %{test_pid: self(), delay: 2_000},
          subscribers: [self()]
        )

      assert_receive {:spectre_reasoning_started, mission_id}, 2_000
      assert {:ok, _pulse} = Spectre.Directive.cancel(mission, :operator_cancelled)

      assert {:ok,
              %Outcome{
                mission_id: ^mission_id,
                status: :cancelled,
                reason: :operator_cancelled
              }} = Spectre.Directive.await(mission, 1_000)

      assert_receive {:spectre_directive, ^mission_id, :outcome, %Outcome{status: :cancelled}},
                     1_000

      assert {:ok, state} = Spectre.Directive.state(mission)
      assert state.pending_request == nil
      assert state.plan.steps == []
      assert_trace(state, :cancelled)
    end

    test "the iteration guard fails a looping Agent before executing its generated step" do
      mission =
        start_agent(InterruptionAgent, "interruption",
          assigns: %{test_pid: self(), version: 2},
          max_iterations: 1
        )

      assert {:ok,
              %Outcome{
                status: :failed,
                reason: {:max_iterations_exceeded, 1}
              }} = Spectre.Directive.await(mission, 3_000)

      assert {:ok, state} = Spectre.Directive.state(mission)
      assert [%{title: "Plan from fresh assigns", status: :pending}] = state.plan.steps
      assert_trace(state, :failed)
    end
  end

  describe "mission completion callbacks owned by the application" do
    test "a successful completion callback records a separate completion result" do
      test_pid = self()

      callback = fn context ->
        send(test_pid, {:completion_called, context.mission.id})
        {:complete_mission, :persisted}
      end

      mission = start_agent(CompletionAgent, "completion", on_complete: callback)

      assert {:ok,
              %Outcome{
                status: :completed,
                result: :core_result,
                completion_result: :persisted
              }} = Spectre.Directive.await(mission, 3_000)

      assert_receive {:completion_called, _mission_id}
    end

    test "an explicit error from the completion callback fails the mission" do
      callback = fn _context -> {:error, :persistence_failed} end
      mission = start_agent(CompletionAgent, "completion", on_complete: callback)

      assert {:ok,
              %Outcome{
                status: :failed,
                reason: {:completion_invocation_failed, :persistence_failed}
              }} = Spectre.Directive.await(mission, 3_000)

      assert {:ok, state} = Spectre.Directive.state(mission)
      assert_trace(state, :failed)
    end

    test "a raised exception in the completion callback is contained and fails the mission" do
      callback = fn _context -> raise "completion crashed" end
      mission = start_agent(CompletionAgent, "completion", on_complete: callback)

      assert {:ok, %Outcome{status: :failed, reason: reason}} =
               Spectre.Directive.await(mission, 3_000)

      assert {:completion_invocation_failed, {:exception, RuntimeError, "completion crashed"}} =
               reason

      assert Process.alive?(mission)
    end

    test "an untrappable completion worker kill is contained by the mission runtime" do
      callback = fn _context -> Process.exit(self(), :kill) end
      mission = start_agent(CompletionAgent, "completion", on_complete: callback)

      assert {:ok,
              %Outcome{
                status: :failed,
                reason: {:completion_invocation_failed, {:worker_crashed, :killed}}
              }} = Spectre.Directive.await(mission, 3_000)

      assert Process.alive?(mission)
    end

    test "a completion timeout fails deterministically and terminates the callback task" do
      callback = fn _context -> Process.sleep(2_000) end

      mission =
        start_agent(CompletionAgent, "completion",
          on_complete: callback,
          request_timeout: 500
        )

      assert {:ok,
              %Outcome{
                status: :failed,
                reason: {:completion_invocation_failed, {:request_timeout, 500}}
              }} = Spectre.Directive.await(mission, 3_000)
    end

    test "denying the completion policy fails without invoking the callback" do
      test_pid = self()

      callback = fn _context ->
        send(test_pid, :forbidden_completion_called)
        {:complete_mission, :should_not_run}
      end

      completion = %Invocation{target: callback, policy: :publish}

      mission =
        start_agent(CompletionAgent, "completion",
          on_complete: completion,
          policy_handler: fn :publish, _context -> :deny end
        )

      assert {:ok,
              %Outcome{
                status: :failed,
                reason: {:completion_policy_denied, :deny}
              }} = Spectre.Directive.await(mission, 3_000)

      refute_receive :forbidden_completion_called, 50
    end

    test "approving the completion policy invokes the callback and preserves both results" do
      test_pid = self()

      callback = fn _context ->
        send(test_pid, :approved_completion_called)
        {:inform, :published}
      end

      completion = %Invocation{target: callback, policy: :publish}

      mission =
        start_agent(CompletionAgent, "completion",
          on_complete: completion,
          policy_handler: fn :publish, _context -> :approved end
        )

      assert {:ok,
              %Outcome{
                status: :completed,
                result: :core_result,
                completion_result: :published
              }} = Spectre.Directive.await(mission, 3_000)

      assert_receive :approved_completion_called
    end

    test "a crashing completion policy can be answered manually to reach a terminal failure" do
      completion = %Invocation{target: fn _context -> :ok end, policy: :publish}

      mission =
        start_agent(CompletionAgent, "completion",
          on_complete: completion,
          policy_handler: fn :publish, _context -> raise "policy service unavailable" end,
          subscribers: [self()]
        )

      request = wait_for_request(mission, :policy)
      assert request.payload.purpose == :on_complete

      assert_receive {:spectre_directive, _mission_id, :error,
                      {:request_worker_failed, :policy,
                       {:exception, RuntimeError, "policy service unavailable"}}},
                     2_000

      assert {:ok, _pulse} = Spectre.Directive.respond(mission, request.id, :deny)

      assert {:ok,
              %Outcome{
                status: :failed,
                reason: {:completion_policy_denied, :deny}
              }} = Spectre.Directive.await(mission, 2_000)
    end
  end

  describe "default Spectre model failures and fallbacks" do
    for mode <- [:provider_error, :malformed_json, :invalid_decision, :raise] do
      @model_failure_mode mode

      test "a #{mode} model failure becomes a user-visible blocker instead of crashing the mission" do
        mode = @model_failure_mode
        model = failing_model(mode)

        mission =
          start_agent(ModelAgent, "model", spectre_opts: [model: model])

        question = wait_for_request(mission, :question)
        assert question.payload.type == :blocker
        refute is_nil(question.payload.question)
        assert Process.alive?(mission)

        assert {:ok, state} = Spectre.Directive.state(mission)
        assert state.status == :waiting
        assert_trace(state, :decision)

        assert {:ok, _pulse} = Spectre.Directive.cancel(mission, {:model_failure, mode})

        assert {:ok,
                %Outcome{
                  status: :cancelled,
                  reason: {:model_failure, ^mode}
                }} = Spectre.Directive.await(mission, 1_000)
      end
    end

    test "a missing model adapter is surfaced as a blocker request" do
      mission = start_agent(ModelAgent, "model")
      question = wait_for_request(mission, :question)

      assert question.payload.type == :blocker
      assert inspect(question.payload.question) =~ "missing_llm_adapter"
      assert {:ok, _pulse} = Spectre.Directive.cancel(mission)
    end

    test "a runtime timeout around a slow model produces a correlated blocker" do
      model = fn _prompt, _opts ->
        Process.sleep(2_000)
        {:ok, ~s({"kind":"blocked","reason":"late"})}
      end

      mission =
        start_agent(ModelAgent, "model",
          spectre_opts: [model: model],
          request_timeout: 500
        )

      question = wait_for_request(mission, :question)
      assert question.payload.question == {:request_timeout, 500}
      assert {:ok, %Request{id: request_id}} = Spectre.Directive.request(mission)
      assert request_id == question.id
      assert {:ok, _pulse} = Spectre.Directive.cancel(mission, :slow_model)
    end

    test "Spectre LLM fallback completes the mission after the primary provider fails" do
      test_pid = self()
      primary = fn _prompt, _opts -> {:error, :primary_down} end

      fallback = fn prompt, opts ->
        send(test_pid, {:fallback_model_called, Keyword.get(opts, :primary_error)})
        valid_model_response(prompt)
      end

      mission =
        start_agent(ModelAgent, "model", spectre_opts: [model: primary, fallback: fallback])

      assert {:ok, %Outcome{status: :completed, result: "model_flow_done"}} =
               Spectre.Directive.await(mission, 3_000)

      assert_receive {:fallback_model_called, :primary_down}
      assert_receive {:fallback_model_called, :primary_down}
    end

    test "fenced JSON returned by a model is decoded for a complete Agent mission" do
      model = fn prompt, _opts ->
        {:ok, payload} = valid_model_response(prompt)
        {:ok, "```json\n#{payload}\n```"}
      end

      mission = start_agent(ModelAgent, "model", spectre_opts: [model: model])

      assert {:ok, %Outcome{status: :completed, result: "model_flow_done"}} =
               Spectre.Directive.await(mission, 3_000)
    end

    test "the default model boundary accepts a decision envelope" do
      model = fn prompt, _opts ->
        {:ok, direct} = valid_model_response(prompt)
        {:ok, decision} = Jason.decode(direct)
        {:ok, Jason.encode!(%{decision: decision})}
      end

      mission = start_agent(ModelAgent, "model", spectre_opts: [model: model])

      assert {:ok, %Outcome{status: :completed, result: "model_flow_done"}} =
               Spectre.Directive.await(mission, 3_000)
    end
  end

  defp start_agent(agent, directive, opts \\ []) do
    assert {:ok, mission} = agent.start_directive(directive, opts)
    on_exit(fn -> safe_stop(mission) end)
    mission
  end

  defp wait_for_request(mission, kind, attempts \\ 400)

  defp wait_for_request(_mission, kind, 0),
    do: flunk("timed out waiting for #{inspect(kind)} request")

  defp wait_for_request(mission, kind, attempts) do
    case Spectre.Directive.request(mission) do
      {:ok, %Request{kind: ^kind} = request} ->
        request

      {:ok, _other} ->
        Process.sleep(5)
        wait_for_request(mission, kind, attempts - 1)

      {:error, reason} ->
        flunk("mission disappeared while waiting for a request: #{inspect(reason)}")
    end
  end

  defp wait_for_request_except(mission, kind, excluded_id, attempts \\ 400)

  defp wait_for_request_except(_mission, kind, excluded_id, 0),
    do: flunk("timed out waiting for a new #{inspect(kind)} request after #{excluded_id}")

  defp wait_for_request_except(mission, kind, excluded_id, attempts) do
    case Spectre.Directive.request(mission) do
      {:ok, %Request{kind: ^kind, id: id} = request} when id != excluded_id ->
        request

      {:ok, _other} ->
        Process.sleep(5)
        wait_for_request_except(mission, kind, excluded_id, attempts - 1)

      {:error, reason} ->
        flunk("mission disappeared while waiting for a request: #{inspect(reason)}")
    end
  end

  defp assert_trace(state, type) do
    assert Enum.any?(state.trace, &(&1.type == type)),
           "expected trace #{inspect(type)}, got: #{inspect(Enum.map(state.trace, & &1.type))}"
  end

  defp failing_model(:provider_error), do: fn _prompt, _opts -> {:error, :provider_down} end
  defp failing_model(:malformed_json), do: fn _prompt, _opts -> {:ok, "not-json"} end

  defp failing_model(:invalid_decision) do
    fn _prompt, _opts -> {:ok, Jason.encode!(%{kind: "invented_operation"})} end
  end

  defp failing_model(:raise), do: fn _prompt, _opts -> raise "model adapter crashed" end

  defp valid_model_response(prompt) do
    response =
      cond do
        String.contains?(prompt, ~s("operation":"plan")) ->
          %{kind: "propose_plan", plan: [%{title: "Finish", invoke: "finish"}]}

        String.contains?(prompt, ~s("operation":"mission_review")) ->
          %{kind: "complete_mission", result: "model_flow_done"}

        true ->
          %{kind: "blocked", reason: "unexpected operation"}
      end

    {:ok, Jason.encode!(response)}
  end

  defp safe_stop(mission) do
    case Spectre.Directive.stop(mission) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end
end
