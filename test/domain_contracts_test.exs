defmodule SpectreDirective.DomainContractsTest do
  use ExUnit.Case, async: true

  alias SpectreDirective.AgentDecision
  alias SpectreDirective.Context
  alias SpectreDirective.Information
  alias SpectreDirective.Invocation
  alias SpectreDirective.Invocation.Result
  alias SpectreDirective.Loop.State
  alias SpectreDirective.Mission
  alias SpectreDirective.MissionBlueprint
  alias SpectreDirective.Outcome
  alias SpectreDirective.Plan
  alias SpectreDirective.PlanPatch
  alias SpectreDirective.Pulse
  alias SpectreDirective.Request
  alias SpectreDirective.Step
  alias SpectreDirective.Trace.Entry
  alias SpectreDirective.WorkingContext

  describe "mission, step, and information construction" do
    test "builds missions from every accepted representation" do
      mission =
        Mission.new("Research client",
          id: "mission-fixed",
          context: :sales,
          success: "report",
          constraints: :safe,
          risk_boundaries: [:external_write],
          metadata: [owner: :agent],
          status: :running
        )

      assert mission.id == "mission-fixed"
      assert mission.goal == "Research client"
      assert mission.context == :sales
      assert mission.success_criteria == "report"
      assert mission.constraints == [:safe]
      assert mission.risk_boundaries == [:external_write]
      assert mission.metadata == %{owner: :agent}
      assert mission.status == :running

      from_strings =
        Mission.new(%{
          "objective" => "Verify client",
          "success" => "verified",
          "constraints" => ["read-only"],
          "metadata" => %{"source" => "test"}
        })

      assert from_strings.goal == "Verify client"
      assert from_strings.success_criteria == "verified"
      assert from_strings.constraints == ["read-only"]

      existing = Mission.new(%Mission{goal: "Existing", id: nil, status: nil}, status: :draft)
      assert is_binary(existing.id)
      assert existing.status == :draft
      assert Mission.new(existing).id == existing.id
    end

    test "builds and overrides complete step attributes" do
      invoke = fn _context -> :ok end

      step =
        Step.new(%{
          "id" => "step-1",
          "title" => "Read page",
          "kind" => :observe,
          "purpose" => "Collect facts",
          "reason" => "Need evidence",
          "input" => %{url: "/client"},
          "expects" => :page,
          "done_when" => :loaded,
          "invocation" => invoke,
          "policy" => :read,
          "risk" => :medium,
          "status" => :running,
          "owner" => :host,
          "attempts" => 2,
          "evidence" => :fact,
          "result" => :partial,
          "source" => :generated,
          "flexibility" => :agentic,
          "prompt" => "Read it",
          "metadata" => %{"format" => "html"}
        })

      assert step.id == "step-1"
      assert step.expected_output == :page
      assert step.done_condition == :loaded
      assert step.invoke == invoke
      assert step.evidence == [:fact]
      assert step.metadata == %{"format" => "html"}

      changed = Step.new(step, title: "Changed", status: :completed, result: :done)
      assert changed.title == "Changed"
      assert changed.status == :completed
      assert changed.result == :done

      assert Step.new("Simple").title == "Simple"
      assert Step.new(%{}).title == "Untitled step"
    end

    test "preserves information identity while applying run-specific attributes" do
      inserted_at = ~U[2026-01-01 00:00:00Z]

      information =
        Information.new(%{fact: 1},
          id: "info-1",
          source: :tool,
          step_id: "step-1",
          trust: :trusted,
          metadata: %{a: 1},
          inserted_at: inserted_at
        )

      assert information.inserted_at == inserted_at
      assert information.content == %{fact: 1}

      updated =
        Information.new(information,
          source: :user,
          step_id: "step-2",
          trust: :untrusted,
          metadata: %{b: 2}
        )

      assert updated.id == "info-1"
      assert updated.source == :user
      assert updated.step_id == "step-2"
      assert updated.trust == :untrusted
      assert updated.metadata == %{a: 1, b: 2}
    end
  end

  describe "working context" do
    test "tracks ordered information, last result, assigns, and revisions" do
      context =
        WorkingContext.new(
          input: %{client: 1},
          assigns: %{locale: "it"},
          information: [:initial],
          last_result: :seed,
          revision: 4
        )

      assert context.input == %{client: 1}
      assert context.revision == 4
      assert [%Information{content: :initial, source: :initial}] = context.information

      context = WorkingContext.add(context, :one, source: :application)
      assert context.last_result == :one
      assert context.revision == 5

      context = WorkingContext.add(context, :two, last_result: :override)
      assert context.last_result == :override

      unchanged = WorkingContext.add_many(context, [])
      assert unchanged == context

      context = WorkingContext.add_many(context, [:three, :four], source: :batch)
      assert Enum.map(context.information, & &1.content) == [:initial, :one, :two, :three, :four]
      assert context.last_result == :four

      context = WorkingContext.add_many(context, [:five], last_result: :batch_result)
      assert context.last_result == :batch_result

      context = WorkingContext.put_assigns(context, %{locale: "en", tenant: 7})
      assert context.assigns == %{locale: "en", tenant: 7}
      assert context.revision == 10
    end
  end

  describe "plan operations" do
    test "builds, selects, indexes, and revises steps" do
      first = Step.new("First", id: "first")
      second = Step.new("Second", id: "second")
      plan = Plan.new([first, %{id: "second", title: "Second"}], id: "plan-1", reason: "start")

      assert plan.id == "plan-1"
      assert Enum.map(Plan.pending_steps(plan), & &1.id) == ["first", "second"]
      assert Plan.current_step(plan) == nil
      assert Plan.next_pending(plan).id == "first"

      plan = Plan.put_current(plan, first)
      assert Plan.current_step(plan).status == :running
      assert Plan.next_pending(plan).id == "second"

      completed = %{Plan.current_step(plan) | status: :completed, result: :done}
      plan = Plan.update_step(plan, completed)
      assert Enum.map(plan.completed_steps, & &1.id) == ["first"]

      skipped = %{second | status: :skipped}
      plan = Plan.update_step(plan, skipped)
      assert Enum.map(plan.skipped_steps, & &1.id) == ["second"]
      assert Plan.put_current(plan, nil).current_step_id == nil

      plan = Plan.add_step(plan, %{id: "third", title: "Third"}, "need more")
      assert List.last(plan.steps).source == :generated
      assert plan.version == 2

      plan = Plan.remove_matching(plan, &(&1.id == "third"), "remove extra")
      refute Enum.any?(plan.steps, &(&1.id == "third"))
      assert plan.version == 3

      plan = Plan.revise(plan, "metadata only")
      assert plan.version == 4
      assert List.last(plan.revision_history).change == nil
    end

    test "accepts keyword and string-keyed plan payloads" do
      keyword_plan = Plan.new(steps: [%{title: "Keyword"}])
      assert hd(keyword_plan.steps).title == "Keyword"

      mapped =
        Plan.new(%{
          "id" => "mapped",
          "version" => 3,
          "reason" => "changed",
          "source" => :hybrid,
          "steps" => [%{"id" => "s", "title" => "Mapped"}],
          "skipped_steps" => [%{"title" => "Skipped"}],
          "completed_steps" => [%{"title" => "Completed"}],
          "revision_history" => [%{version: 2}],
          "current_step_id" => "s"
        })

      assert mapped.id == "mapped"
      assert mapped.version == 3
      assert mapped.source == :hybrid
      assert Plan.current_step(mapped).title == "Mapped"
    end
  end

  describe "atomic plan patches" do
    setup do
      completed = Step.new("Completed", id: "done", status: :completed)
      first = Step.new("First", id: "first")
      second = Step.new("Second", id: "second")
      {:ok, plan: Plan.new([completed, first, second], id: "plan", source: :hybrid)}
    end

    test "normalizes map operations and applies every supported operation", %{plan: plan} do
      patch =
        PlanPatch.new(%{
          "base_version" => 1,
          "reason" => "Adapt",
          "metadata" => %{"agent" => true},
          "operations" => [
            %{
              "op" => "insert_after",
              "after" => "first",
              "step" => %{id: "inserted", title: "Inserted"}
            },
            %{
              "type" => "replace",
              "step_id" => "second",
              "step" => %{id: "replacement", title: "Replacement"}
            },
            %{"operation" => "add", "step" => %{id: "added", title: "Added"}},
            %{"op" => "skip", "step_id" => "first", "reason" => "not needed"}
          ]
        })

      assert patch.metadata == %{"agent" => true}
      assert {:ok, changed} = PlanPatch.apply(plan, patch)
      assert changed.version == 2
      assert changed.reason == "Adapt"

      assert Enum.map(changed.steps, & &1.id) == [
               "done",
               "first",
               "inserted",
               "replacement",
               "added"
             ]

      assert Enum.find(changed.steps, &(&1.id == "first")).status == :skipped
      assert Enum.find(changed.steps, &(&1.id == "inserted")).source == :generated
      assert length(changed.revision_history) == 1
    end

    test "removes and reorders only mutable pending steps", %{plan: plan} do
      assert {:ok, removed} = PlanPatch.apply(plan, [{:remove, "first"}])
      assert Enum.map(removed.steps, & &1.id) == ["done", "second"]

      assert {:ok, reordered} =
               PlanPatch.apply(plan, %{
                 operations: [%{op: :reorder, step_ids: ["second", "first"]}]
               })

      assert Enum.map(reordered.steps, & &1.id) == ["done", "second", "first"]
    end

    test "rejects stale, missing, immutable, unskippable, invalid, and partial patches", %{
      plan: plan
    } do
      assert {:error, {:stale_plan_patch, 9, 1}} =
               PlanPatch.apply(plan, %PlanPatch{base_version: 9})

      assert {:error, {:step_not_found, "missing"}} =
               PlanPatch.apply(plan, [{:insert_after, "missing", %{title: "X"}}])

      assert {:error, {:step_not_found, "missing"}} =
               PlanPatch.apply(plan, [{:remove, "missing"}])

      assert {:error, {:step_not_mutable, "done", :completed}} =
               PlanPatch.apply(plan, [{:remove, "done"}])

      assert {:error, {:step_not_mutable, "done", :completed}} =
               PlanPatch.apply(plan, [{:replace, "done", %{title: "X"}}])

      assert {:error, {:step_not_skippable, "done", :completed}} =
               PlanPatch.apply(plan, [{:skip, "done", :late}])

      assert {:error, {:invalid_reorder, ["first"], ["first", "second"]}} =
               PlanPatch.apply(plan, [{:reorder, ["first"]}])

      assert {:error, {:invalid_plan_operation, {:unknown, :value}}} =
               PlanPatch.apply(plan, {:unknown, :value})

      assert {:error, {:step_not_found, "missing"}} =
               PlanPatch.apply(plan, [
                 {:add, %{id: "would-have-been-added", title: "Transient"}},
                 {:remove, "missing"}
               ])

      refute Enum.any?(plan.steps, &(&1.id == "would-have-been-added"))
    end

    test "constructs patches from structs, keyword lists, tuple operations, and unknown maps" do
      patch = %PlanPatch{reason: "existing"}
      assert PlanPatch.new(patch) == patch
      assert PlanPatch.new(base_version: 2, operations: [{:add, %{title: "A"}}]).base_version == 2
      assert PlanPatch.new({:remove, "x"}).operations == [{:remove, "x"}]

      unknown = %{op: "unknown", value: 1}
      assert PlanPatch.new([unknown]).operations == [unknown]
    end
  end

  describe "decisions and invocation results" do
    test "normalizes all tuple decision forms" do
      target = fn _ -> :ok end

      cases = [
        {{:invoke, target}, :invoke},
        {{:invoke, target, policy: :safe}, :invoke},
        {{:ask, "Which client?"}, :ask},
        {{:ask_policy, :external}, :policy},
        {{:ask_policy, :external, target}, :policy},
        {{:propose_plan, [%{title: "A"}]}, :propose_plan},
        {{:propose_patch, [{:add, %{title: "A"}}]}, :propose_patch},
        {{:propose_patch, [{:add, %{title: "A"}}], :fact}, :propose_patch},
        {{:complete_step, :done}, :complete_step},
        {{:complete_mission, :done}, :complete_mission},
        {{:blocked, :missing}, :blocked},
        {{:error, :failed}, :blocked}
      ]

      Enum.each(cases, fn {input, kind} ->
        assert {:ok, %AgentDecision{kind: ^kind}} = AgentDecision.new(input)
      end)

      assert {:ok, decision} = AgentDecision.new({:ok, {:ask, "Again?"}})
      assert decision.question == "Again?"
      assert AgentDecision.new(decision) == {:ok, decision}
    end

    test "normalizes map decisions and rejects invalid values" do
      assert {:ok, decision} =
               AgentDecision.new(%{
                 "kind" => "invoke",
                 "invocation" => %{
                   "target" => {String, :upcase},
                   "policy" => :safe,
                   "metadata" => %{"tool" => true}
                 },
                 "metadata" => %{"turn" => 1}
               })

      assert decision.invocation.target == {String, :upcase}
      assert decision.invocation.policy == :safe

      assert {:ok, map_target} =
               AgentDecision.new(%{kind: :invoke, invocation: %{name: "symbolic"}})

      assert map_target.invocation.target == %{name: "symbolic"}

      assert {:error, {:invalid_agent_decision, %{kind: :unknown}}} =
               AgentDecision.new(%{kind: :unknown})

      assert {:error, {:invalid_agent_decision, :bad}} = AgentDecision.new(:bad)

      assert {:error, {:invalid_agent_decision, _attrs, _error}} =
               AgentDecision.new(%{kind: :ask, metadata: :not_a_map})
    end

    test "builds invocations and normalizes every invocation result" do
      invocation = Invocation.new(:target, policy: :safe, metadata: %{one: 1})
      updated = Invocation.new(invocation, policy: :safer, metadata: %{two: 2})
      assert updated == %Invocation{target: :target, policy: :safer, metadata: %{one: 1, two: 2}}

      existing = %Result{transition: :ask, question: "existing"}

      cases = [
        {existing, existing},
        {{:ok, :value}, %Result{transition: :reason, information: [:value]}},
        {:ok, %Result{transition: :reason, information: [:ok]}},
        {{:inform, nil}, %Result{transition: :reason, information: []}},
        {{:complete_step, :step},
         %Result{transition: :complete_step, step_result: :step, information: [:step]}},
        {{:complete_mission, :mission},
         %Result{transition: :complete_mission, mission_result: :mission, information: [:mission]}},
        {{:propose_patch, [{:remove, "x"}], :fact},
         %Result{transition: :propose_patch, plan_patch: [{:remove, "x"}], information: [:fact]}},
        {{:ask, "question"}, %Result{transition: :ask, question: "question"}},
        {{:error, :failed},
         %Result{transition: :reason, error: :failed, information: [%{error: :failed}]}},
        {:plain, %Result{transition: :reason, information: [:plain]}}
      ]

      Enum.each(cases, fn {input, expected} ->
        assert {:ok, actual} = Result.normalize(input)
        assert Map.from_struct(actual) == Map.from_struct(expected)
      end)
    end
  end

  describe "blueprints, state snapshots, requests, and outcomes" do
    test "builds and independently instantiates reusable blueprints" do
      plan = Plan.new([Step.new("Existing", id: "old", status: :completed)])

      blueprint =
        MissionBlueprint.new(
          id: "blueprint",
          name: :research,
          mission: %{goal: "Research"},
          plan: plan,
          mode: :adaptive,
          source: :hybrid,
          on_complete: :store,
          metadata: %{owner: :test}
        )

      assert blueprint.name == "research"
      assert blueprint.mode == :autonomous
      assert blueprint.plan == plan

      first = MissionBlueprint.instantiate(blueprint, id: "run-1")
      second = MissionBlueprint.instantiate(blueprint, id: "run-2")
      assert first.mission.id == "run-1"
      assert second.mission.id == "run-2"
      refute first.plan.id == second.plan.id
      refute hd(first.plan.steps).id == hd(second.plan.steps).id
      assert hd(first.plan.steps).status == :pending

      from_mission =
        MissionBlueprint.from_mission("Goal",
          name: "named",
          mode: :strict,
          steps: [%{title: "One"}],
          source: :authored
        )

      assert from_mission.mode == :fixed
      assert from_mission.name == "named"
      assert length(from_mission.plan.steps) == 1

      fallback = MissionBlueprint.new(mission: "Fallback", mode: :invalid, plan: [%{title: "P"}])
      assert fallback.mode == :guided
      assert hd(fallback.plan.steps).title == "P"
    end

    test "validates loop state and creates callback-safe projections" do
      invoke = fn _ -> :ok end

      assert {:ok, state} =
               State.new(
                 mission: "Inspect",
                 context: :ctx,
                 success: :done,
                 steps: [%{id: "step", title: "Read", invoke: invoke}],
                 input: :input,
                 assigns: %{tenant: 1},
                 information: [:seed],
                 mode: :strict,
                 reasoner: :reasoner,
                 reasoner_opts: [temperature: 0],
                 max_iterations: 7,
                 metadata: %{run: 1}
               )

      assert state.mode == :fixed
      assert state.plan_confirmed?
      assert state.max_iterations == 7
      assert state.mission.status == :running

      context = State.context(state, :inspect)
      projected = Context.to_map(context)
      assert projected.operation == :inspect
      assert projected.input == :input
      assert projected.assigns == %{tenant: 1}
      assert projected.step == nil
      refute Map.has_key?(hd(projected.plan.steps), :invoke)
      assert hd(projected.plan.steps).invokable?
      assert hd(projected.information).content == :seed

      state = State.add_trace(state, :custom, "Changed", %{a: 1})
      assert List.last(state.trace).type == :custom
      state = State.put_status(state, :paused)
      assert state.status == :paused
      assert state.mission.status == :paused

      assert {:ok, generated} = State.new(mission: "Generated")
      assert generated.mission.goal == "Generated"
      refute generated.plan_confirmed?
      assert generated.plan.source == :agent_generated

      assert {:error, :mission_required} = State.new(%{})
      assert {:error, :mission_required} = State.new(%{"mission" => "No atom key"})
      assert {:error, :mission_goal_required} = State.new(mission: "   ")
      assert {:error, {:invalid_loop_options, :bad}} = State.new(:bad)
      assert {:error, {:invalid_plan, _}} = State.new(mission: "Goal", plan: :bad)
    end

    test "projects a selected step and plan history without executable targets" do
      step = Step.new("Run", id: "step", invoke: fn _ -> :ok end)
      plan = Plan.new([step]) |> Plan.put_current(step) |> Plan.revise("selected", :change)
      mission = Mission.new("Goal", id: "mission", status: :running)
      info = Information.new(:fact, id: "info")

      context = %Context{
        mission: mission,
        plan: plan,
        mode: :guided,
        plan_status: :waiting,
        step: Plan.current_step(plan),
        information: [info],
        last_result: :fact,
        input: :input,
        assigns: %{a: 1},
        revision: 2,
        iteration: 3,
        operation: :step
      }

      mapped = Context.to_map(context)
      assert mapped.step.id == "step"
      assert mapped.step.invokable?
      refute Map.has_key?(mapped.step, :invoke)

      assert [%{version: 2, reason: "selected", timestamp: %DateTime{}}] =
               mapped.plan.revision_history
    end

    test "builds correlated requests, pulse controls, outcomes, trace entries, and protocol" do
      {:ok, state} = State.new(mission: "Goal", steps: [%{id: "s", title: "S"}])
      step = hd(state.plan.steps)
      state = %{state | plan: Plan.put_current(state.plan, step)}
      context = State.context(state, :reason)

      request = Request.new(:reason, context, id: "request", target: :model, payload: %{a: 1})
      assert request.id == "request"
      assert request.mission_id == state.mission.id
      assert request.step_id == "s"
      assert request.plan_version == 1
      assert request.context_revision == 0
      assert request.payload == %{a: 1}

      pulse = Pulse.from_loop(%{state | pending_request: request, status: :waiting})
      assert pulse.pending_request == request
      assert pulse.controls == [:respond, :inform, :pause, :cancel]
      assert Pulse.from_loop(%{state | status: :paused}).controls == [:resume, :cancel, :inform]

      outcome = Outcome.new(state.mission.id, :completed, result: :ok, metadata: %{a: 1})
      terminal = Pulse.from_loop(%{state | status: :completed, outcome: outcome})
      assert terminal.controls == []
      assert terminal.outcome == outcome

      entry = Entry.new(state.mission.id, :tested, "Tested", %{ok: true})
      assert entry.type == :tested
      assert entry.data == %{ok: true}
      assert %DateTime{} = entry.timestamp

      protocol = Spectre.Directive.protocol()
      assert protocol.version == 1
      assert Map.has_key?(protocol.decisions, :invoke)
      assert "reorder" in protocol.patch_operations
      assert SpectreDirective.protocol() == protocol
    end
  end
end
