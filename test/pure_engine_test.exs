defmodule SpectreDirective.PureEngineTest do
  use ExUnit.Case, async: true

  alias Spectre.Directive.Invoker
  alias SpectreDirective.Invocation.Result
  alias SpectreDirective.Loop.Completion
  alias SpectreDirective.Loop.Engine
  alias SpectreDirective.Loop.PlanReducer
  alias SpectreDirective.Loop.State
  alias SpectreDirective.Outcome
  alias SpectreDirective.Plan
  alias SpectreDirective.PlanPatch
  alias SpectreDirective.Request
  alias SpectreDirective.Step

  describe "manual mission driving" do
    test "the host can manually answer every boundary from plan creation to outcome" do
      assert {:ok, loop} =
               Spectre.Directive.new(
                 mission: "Research the client",
                 success: "Return two verified facts",
                 mode: :autonomous,
                 execution: :manual
               )

      assert {:request, %Request{kind: :reason} = plan_request, loop} =
               Spectre.Directive.next(loop)

      assert plan_request.context.operation == :plan

      assert {:request, %Request{kind: :reason} = first_step, loop} =
               Spectre.Directive.respond(loop, plan_request.id, {
                 :propose_plan,
                 [
                   %{id: "read", title: "Read client page"},
                   %{id: "verify", title: "Verify facts"}
                 ]
               })

      assert first_step.context.operation == :step
      assert first_step.context.step.title == "Read client page"

      assert {:request, %Request{kind: :question} = question, loop} =
               Spectre.Directive.respond(loop, first_step.id, {:ask, "What is the page URL?"})

      assert question.payload.question == "What is the page URL?"

      assert {:request, %Request{kind: :reason} = informed_step, loop} =
               Spectre.Directive.respond(loop, question.id, "https://example.test/client")

      assert informed_step.context.last_result == "https://example.test/client"
      assert length(informed_step.context.information) == 1

      read = fn context ->
        assert context.step.title == "Read client page"
        {:complete_step, %{facts: [:one, :two]}}
      end

      assert {:request, %Request{kind: :invoke} = invocation, loop} =
               Spectre.Directive.respond(loop, informed_step.id, {:invoke, read})

      invocation_result = Invoker.call(invocation.target, invocation.context)

      assert {:request, %Request{kind: :reason} = verify_step, loop} =
               Spectre.Directive.respond(loop, invocation.id, invocation_result)

      assert verify_step.context.step.title == "Verify facts"
      assert Enum.any?(verify_step.context.information, &(&1.content == %{facts: [:one, :two]}))

      assert {:request, %Request{kind: :reason} = review, loop} =
               Spectre.Directive.respond(loop, verify_step.id, {:complete_step, :verified})

      assert review.context.operation == :mission_review

      assert {:done, %Outcome{status: :completed, result: result}, finished} =
               Spectre.Directive.respond(loop, review.id, {:complete_mission, %{facts: 2}})

      assert result == %{facts: 2}
      assert finished.status == :completed

      assert Enum.map(finished.plan.completed_steps, & &1.title) == [
               "Read client page",
               "Verify facts"
             ]
    end

    test "guided plans and patches wait for editable confirmation" do
      {:ok, loop} = Engine.new(mission: "Guided", mode: :guided)
      {:request, plan_request, loop} = Engine.next(loop)

      assert {:request, %Request{kind: :confirmation} = confirmation, loop} =
               Engine.respond(loop, plan_request.id, {:propose_plan, [%{title: "Draft"}]})

      assert confirmation.payload.proposal_type == :plan
      assert {:plan, %Plan{}} = loop.pending_proposal

      assert {:error, {:invalid_confirmation, :maybe}, ^loop} =
               Engine.respond(loop, confirmation.id, :maybe)

      edited = [%{id: "approved", title: "Approved"}]

      assert {:request, %Request{kind: :reason} = step_request, loop} =
               Engine.respond(loop, confirmation.id, {:edit, edited})

      assert step_request.context.step.title == "Approved"
      assert loop.pending_proposal == nil

      patch = [{:add, %{id: "second", title: "Second"}}]

      assert {:request, %Request{kind: :confirmation} = patch_confirmation, loop} =
               Engine.respond(loop, step_request.id, {:propose_patch, patch, :new_fact})

      assert patch_confirmation.payload.proposal_type == :patch

      assert {:request, %Request{kind: :reason} = resumed, loop} =
               Engine.respond(loop, patch_confirmation.id, {:accept, patch})

      assert resumed.context.step.id == "approved"
      assert Enum.map(loop.plan.steps, & &1.id) == ["approved", "second"]
      assert loop.plan.version == 3
    end

    test "rejected guided proposals become information for a fresh planning turn" do
      {:ok, loop} = Engine.new(mission: "Guided", mode: :guided)
      {:request, plan_request, loop} = Engine.next(loop)

      {:request, confirmation, loop} =
        Engine.respond(loop, plan_request.id, {:propose_plan, [%{title: "Unsafe"}]})

      assert {:request, %Request{kind: :reason} = retry, loop} =
               Engine.respond(loop, confirmation.id, {:reject, :unsafe})

      assert retry.context.operation == :plan
      assert loop.pending_proposal == nil
      assert loop.working_context.last_result == %{proposal_rejected: :unsafe}
      assert Enum.any?(loop.trace, &(&1.type == :proposal_rejected))
    end

    test "fixed mode rejects generated plan changes" do
      {:ok, loop} = Engine.new(mission: "Fixed", mode: :fixed)
      {:request, request, loop} = Engine.next(loop)

      assert {:error, {:plan_change_not_allowed, :plan}, ^loop} =
               Engine.respond(loop, request.id, {:propose_plan, [%{title: "No"}]})
    end
  end

  describe "authored invocations and policies" do
    test "authored policy is decided manually before invocation" do
      target = fn _context -> {:inform, :page} end

      {:ok, loop} =
        Engine.new(
          mission: "Read",
          mode: :fixed,
          steps: [%{id: "read", title: "Read", invoke: target, policy: :external_read}]
        )

      assert {:request, %Request{kind: :policy} = policy, loop} = Engine.next(loop)
      assert policy.payload.policy == :external_read
      assert policy.payload.purpose == :authored_step

      assert {:request, %Request{kind: :invoke} = invocation, loop} =
               Engine.respond(loop, policy.id, {:ok, :allow})

      assert invocation.target == target

      assert {:request, %Request{kind: :reason} = reasoning, _loop} =
               Engine.respond(loop, invocation.id, {:ok, :page})

      assert reasoning.context.last_result == :page
      assert reasoning.context.step.attempts == 1
      assert Enum.any?(reasoning.context.information, &(&1.content == :page))

      assert {:request, %Request{kind: :reason}, denied_loop} =
               denied_authored_invocation(:deny)

      assert denied_loop.working_context.last_result == %{
               policy: :external_read,
               decision: :deny
             }
    end

    test "reasoner can request standalone policy or policy-protected invocation" do
      {:ok, loop} = Engine.new(mission: "Policy", steps: [%{title: "Decide"}])
      {:request, reason, loop} = Engine.next(loop)

      assert {:request, %Request{kind: :policy} = policy, loop} =
               Engine.respond(loop, reason.id, {:ask_policy, :human_review})

      assert policy.payload.invocation == nil

      assert {:request, %Request{kind: :reason}, loop} =
               Engine.respond(loop, policy.id, :approved)

      {:request, reason, loop} = Engine.next(loop)
      target = fn _ -> {:complete_mission, :ok} end

      assert {:request, %Request{kind: :policy} = protected, loop} =
               Engine.respond(loop, reason.id, {:ask_policy, :execute, target})

      assert {:request, %Request{kind: :invoke}, _loop} =
               Engine.respond(loop, protected.id, true)
    end

    test "invocation can ask, patch, report errors, complete steps, or complete mission" do
      target = fn _ -> :unused end

      {:ok, loop} =
        Engine.new(
          mission: "Transitions",
          mode: :autonomous,
          steps: [
            %{id: "one", title: "One", invoke: target},
            %{id: "two", title: "Two", invoke: target}
          ]
        )

      {:request, invocation, loop} = Engine.next(loop)

      assert {:request, %Request{kind: :question} = question, loop} =
               Engine.respond(loop, invocation.id, {:ask, "Need input"})

      assert {:request, %Request{kind: :reason}, loop} =
               Engine.respond(loop, question.id, :answer)

      # A reasoner-supplied invocation exercises the recoverable error path.
      {:request, reason, loop} = Engine.next(loop)
      {:request, retry_invocation, loop} = Engine.respond(loop, reason.id, {:invoke, target})

      assert {:request, %Request{kind: :reason} = after_error, loop} =
               Engine.respond(loop, retry_invocation.id, {:error, :temporary})

      assert after_error.context.last_result == %{error: :temporary}

      patch = [{:add, %{id: "extra", title: "Extra"}}]

      {:request, patch_invocation, loop} =
        Engine.respond(loop, after_error.id, {:invoke, target})

      assert {:request, %Request{kind: :reason}, loop} =
               Engine.respond(loop, patch_invocation.id, {:propose_patch, patch, :discovered})

      assert Enum.any?(loop.plan.steps, &(&1.id == "extra"))

      {:request, reason, loop} = Engine.next(loop)

      assert {:request, %Request{kind: :invoke} = invocation, loop} =
               Engine.respond(loop, reason.id, {:complete_step, :one_done})

      assert {:done, %Outcome{result: :finished}, loop} =
               Engine.respond(loop, invocation.id, {:complete_mission, :finished})

      assert Plan.current_step(loop.plan).attempts == 1
    end

    test "completion invocation records its result and failure" do
      on_complete = fn _context -> {:complete_mission, :stored} end

      {:ok, loop} =
        Engine.new(
          mission: "Complete",
          steps: [%{title: "Finish"}],
          on_complete: on_complete
        )

      {:request, reason, loop} = Engine.next(loop)

      assert {:request, %Request{kind: :invoke} = completion, loop} =
               Engine.respond(loop, reason.id, {:complete_mission, :result})

      assert completion.payload.purpose == :on_complete

      assert {:done, outcome, _loop} =
               Engine.respond(loop, completion.id, {:complete_mission, :stored})

      assert outcome.result == :result
      assert outcome.completion_result == :stored

      {:ok, failed_loop} =
        Engine.new(
          mission: "Fail completion",
          steps: [%{title: "Finish"}],
          on_complete: on_complete
        )

      {:request, reason, failed_loop} = Engine.next(failed_loop)

      {:request, completion, failed_loop} =
        Engine.respond(failed_loop, reason.id, {:complete_mission, :result})

      assert {:done, %Outcome{status: :failed, reason: reason}, _loop} =
               Engine.respond(failed_loop, completion.id, {:error, :storage_failed})

      assert reason == {:completion_invocation_failed, :storage_failed}
    end

    test "completion policy denial fails instead of running the final invocation" do
      final = %SpectreDirective.Invocation{target: fn _ -> :ok end, policy: :publish}

      {:ok, loop} =
        Engine.new(mission: "Publish", steps: [%{title: "Finish"}], on_complete: final)

      {:request, reason, loop} = Engine.next(loop)

      assert {:request, %Request{kind: :policy} = policy, loop} =
               Engine.respond(loop, reason.id, {:complete_mission, :report})

      assert policy.payload.purpose == :on_complete

      assert {:done, %Outcome{status: :failed, reason: failure}, _loop} =
               Engine.respond(loop, policy.id, :deny)

      assert failure == {:completion_policy_denied, :deny}
    end
  end

  describe "correlation, information, and controls" do
    test "rejects missing, stale, invalid, plan-stale, and step-stale responses" do
      {:ok, empty} = Engine.new(mission: "Correlation", steps: [%{id: "one", title: "One"}])
      assert {:error, :no_pending_request, ^empty} = Engine.respond(empty, "none", :ok)
      assert {:error, {:invalid_request_id, :bad}, ^empty} = Engine.respond(empty, :bad, :ok)

      {:request, request, waiting} = Engine.next(empty)

      assert {:error, {:stale_response, "old", expected}, ^waiting} =
               Engine.respond(waiting, "old", :ok)

      assert expected == request.id

      newer_plan = %{waiting | plan: %{waiting.plan | version: 2}}

      assert {:error, {:stale_plan_response, 1, 2}, ^newer_plan} =
               Engine.respond(newer_plan, request.id, {:complete_step, :ok})

      current = Plan.current_step(waiting.plan)
      other = Step.new("Other", id: "other", status: :running)

      different_step = %{
        waiting
        | plan: %{waiting.plan | steps: [current, other], current_step_id: "other"}
      }

      assert {:error, {:stale_step_response, "one", "other"}, ^different_step} =
               Engine.respond(different_step, request.id, {:complete_step, :ok})

      no_step = %{waiting | plan: Plan.put_current(waiting.plan, nil)}

      assert {:error, {:stale_step_response, "one", nil}, ^no_step} =
               Engine.respond(no_step, request.id, {:complete_step, :ok})
    end

    test "new information and assigns invalidate only pending reasoning" do
      {:ok, loop} = Engine.new(mission: "Information", steps: [%{title: "Think"}])
      {:request, reason, loop} = Engine.next(loop)

      assert {:ok, informed} = Engine.inform(loop, :fact, source: :user)
      assert informed.pending_request == nil
      assert informed.status == :running
      assert informed.working_context.last_result == :fact

      assert {:error, :no_pending_request, ^informed} =
               Engine.respond(informed, reason.id, {:complete_step, :late})

      {:request, refreshed, informed} = Engine.next(informed)
      assert refreshed.context.revision == 1

      assert {:ok, assigned} = Engine.assign(informed, %{tenant: 7})
      assert assigned.pending_request == nil
      assert assigned.working_context.assigns == %{tenant: 7}

      target = fn _ -> :ok end
      {:request, next_reason, assigned} = Engine.next(assigned)

      {:request, invocation, assigned} =
        Engine.respond(assigned, next_reason.id, {:invoke, target})

      assert {:ok, still_invoking} = Engine.inform(assigned, :late_fact)
      assert still_invoking.pending_request.id == invocation.id

      assert {:ok, still_invoking} = Engine.assign(still_invoking, %{locale: "it"})
      assert still_invoking.pending_request.id == invocation.id
    end

    test "validates information and assigns and rejects mutation after terminal state" do
      {:ok, loop} = Engine.new(mission: "Validation", steps: [%{title: "One"}])

      assert {:error, {:invalid_information_options, :bad}} = Engine.inform(loop, :fact, :bad)
      assert {:error, {:invalid_assigns, :bad}} = Engine.assign(loop, :bad)

      cancelled = Engine.cancel(loop, :stop)
      assert {:error, :mission_terminal} = Engine.inform(cancelled, :fact)
      assert {:error, :mission_terminal} = Engine.assign(cancelled, %{})
      assert {:error, :mission_terminal} = Engine.pause(cancelled)

      assert {:error, :mission_terminal, ^cancelled} =
               Engine.respond(cancelled, "request", :anything)

      assert Engine.cancel(cancelled, :again) == cancelled
    end

    test "pause, resume, blocked state, cancellation, and iteration limit are deterministic" do
      {:ok, loop} = Engine.new(mission: "Controls", max_iterations: 1)
      assert {:ok, paused} = Engine.pause(loop)
      assert {:blocked, :paused, ^paused} = Engine.next(paused)
      assert {:error, :mission_paused, ^paused} = Engine.respond(paused, "id", :ok)

      assert {:ok, resumed} = Engine.resume(paused)
      assert resumed.status == :running
      assert {:error, :mission_not_paused} = Engine.resume(resumed)

      blocked = State.put_status(resumed, :blocked)
      assert {:blocked, :blocked, ^blocked} = Engine.next(blocked)
      assert {:ok, unblocked} = Engine.resume(blocked)
      assert unblocked.status == :running

      {:request, request, waiting} = Engine.next(unblocked)

      assert {:done, %Outcome{status: :failed, reason: failure}, _loop} =
               Engine.respond(waiting, request.id, {:ask, :answer})

      assert failure == {:max_iterations_exceeded, 1}

      cancelled = Engine.cancel(loop)
      assert cancelled.outcome.reason == :cancelled
      outcome = cancelled.outcome
      assert {:done, ^outcome, ^cancelled} = Engine.next(cancelled)
    end
  end

  describe "plan reducer and completion edge contracts" do
    test "normalizes proposals and all confirmation aliases" do
      {:ok, state} = State.new(mission: "Plan")

      assert {:ok, %Plan{source: :agent_generated}} =
               PlanReducer.normalize_proposed(state, %{"steps" => [%{"title" => "A"}]})

      assert {:ok, %Plan{}} = PlanReducer.normalize_proposed(state, %{steps: [%{title: "A"}]})
      assert {:ok, %Plan{}} = PlanReducer.normalize_proposed(state, Plan.new([%{title: "A"}]))

      assert {:error, {:invalid_proposed_plan, :bad}} =
               PlanReducer.normalize_proposed(state, :bad)

      running = Step.new("Running", status: :running)
      started = %{state | plan: Plan.new([running])}

      assert {:error, :plan_already_started_use_patch} =
               PlanReducer.normalize_proposed(started, [%{title: "New"}])

      proposal = :proposal
      assert PlanReducer.confirmation(:accept, proposal) == {:accept, proposal}
      assert PlanReducer.confirmation(:approved, proposal) == {:accept, proposal}
      assert PlanReducer.confirmation(true, proposal) == {:accept, proposal}
      assert PlanReducer.confirmation({:ok, :accept}, proposal) == {:accept, proposal}
      assert PlanReducer.confirmation({:accept, :edited}, proposal) == {:accept, :edited}
      assert PlanReducer.confirmation({:edit, :edited}, proposal) == {:accept, :edited}
      assert PlanReducer.confirmation({:reject, :why}, proposal) == {:reject, :why}
      assert PlanReducer.confirmation(:reject, proposal) == {:reject, :rejected}
      assert PlanReducer.confirmation(false, proposal) == {:reject, :rejected}

      assert PlanReducer.confirmation(:other, proposal) ==
               {:error, {:invalid_confirmation, :other}}
    end

    test "applies autonomous and confirmed plans and patches" do
      {:ok, autonomous} = State.new(mission: "Auto", mode: :autonomous)
      plan = Plan.new([%{id: "one", title: "One"}], source: :agent_generated)
      assert {:ok, planned} = PlanReducer.apply_change(autonomous, :plan, plan)
      assert planned.plan_confirmed?
      assert planned.plan.version == 2

      patch = %PlanPatch{operations: [{:add, %{id: "two", title: "Two"}}]}
      assert {:ok, patched} = PlanReducer.apply_change(planned, :patch, patch)
      assert Enum.map(patched.plan.steps, & &1.id) == ["one", "two"]

      assert {:ok, confirmed_plan} = PlanReducer.apply_confirmed(autonomous, :plan, plan)
      assert Enum.any?(confirmed_plan.trace, &(&1.type == :proposal_accepted))

      assert {:ok, confirmed_patch} =
               PlanReducer.apply_confirmed(confirmed_plan, :patch, [
                 {:add, %{id: "three", title: "Three"}}
               ])

      assert Enum.any?(confirmed_patch.plan.steps, &(&1.id == "three"))

      versioned = PlanReducer.with_version([{:add, %{title: "X"}}], 8)
      assert versioned.base_version == 8
      assert PlanReducer.with_version(%{versioned | base_version: 3}, 9).base_version == 3

      guided = %{autonomous | mode: :guided}
      assert {:confirm, ^guided} = PlanReducer.apply_change(guided, :plan, plan)

      assert {:error, {:plan_change_not_allowed, :patch}} =
               PlanReducer.apply_change(%{autonomous | mode: :fixed}, :patch, patch)
    end

    test "completion handles no step, repeated completion, cancellation, failure, and output selection" do
      {:ok, state} = State.new(mission: "Complete")
      assert {:error, :no_current_step} = Completion.complete_step(state, :none)

      assert {:complete, completed} = Completion.begin(state, :result)
      assert completed.outcome.result == :result

      already_started = %{state | completion_started?: true}
      assert {:complete, repeated} = Completion.begin(already_started, :second)
      assert repeated.outcome.result == :second

      with_callback = %{state | on_complete: fn _ -> :ok end}
      assert {:invoke, pending, invocation} = Completion.begin(with_callback, :result)
      assert pending.pending_completion_result == :result
      assert is_function(invocation.target, 1)

      request = request_for(pending, :invoke)

      assert {:ok, finished} =
               Completion.finish(
                 pending,
                 request,
                 %Result{transition: :complete_step, step_result: :stored}
               )

      assert finished.outcome.completion_result == :stored

      failed = Completion.fail(state, :broken)
      assert Completion.done_result(failed) == {:done, failed.outcome, failed}

      cancelled = Completion.cancel(state, :stop)
      assert cancelled.outcome.status == :cancelled
      assert Completion.cancel(cancelled, :again) == cancelled
      assert Completion.cancel(failed, :again) == failed
      assert Completion.cancel(completed, :again) == completed
    end
  end

  defp denied_authored_invocation(decision) do
    target = fn _context -> {:inform, :page} end

    {:ok, loop} =
      Engine.new(
        mission: "Denied",
        mode: :fixed,
        steps: [%{title: "Read", invoke: target, policy: :external_read}]
      )

    {:request, policy, loop} = Engine.next(loop)
    Engine.respond(loop, policy.id, decision)
  end

  defp request_for(state, kind) do
    Request.new(kind, State.context(state, kind), payload: %{purpose: :on_complete})
  end
end
