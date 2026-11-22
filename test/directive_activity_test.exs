defmodule SpectreDirective.DirectiveActivityTest do
  use ExUnit.Case, async: false

  alias Spectre.Server
  alias Spectre.Server.GAM.Managed

  @timeout 5_000
  @publication_class "test.directive.publish"

  defmodule Model do
    @behaviour Spectre.LLM

    @impl true
    def complete(prompt, _opts) do
      send(Process.whereis(SpectreDirective.DirectiveActivityTest), {:infer, self(), prompt})

      receive do
        {:decision, decision} -> {:ok, Spectre.JSON.encode!(decision)}
      after
        5_000 -> {:error, :test_model_timed_out}
      end
    end
  end

  defmodule Documents do
    @behaviour Spectre.Server.GAM.EffectAdapter

    use Spectre.Stack.Installable, id: :documents, version: "0.1.0"

    @impl Spectre.Stack.Installable
    def integration(_config) do
      Spectre.Integration.new()
      |> Spectre.Integration.tool(:publish, __MODULE__,
        args: [id: :string],
        governed: :publish
      )
    end

    @impl Spectre.Stack.Installable
    def effects(_config) do
      %{
        publish: %{
          contract: 1,
          adapter: __MODULE__,
          operation: :publish,
          side_effect: :idempotent,
          material: :arguments,
          partition: [:subject],
          schema_hash: nil,
          config: %{}
        }
      }
    end

    def prepare(:publish, %{"id" => id}, _context), do: {:ok, %{id: id}}
    def prepare(:publish, _, _context), do: {:error, :invalid_publish_arguments}
    def project(:publish, result), do: {:ok, result}

    @impl true
    def execute_effect(:publish, %{id: "held"}, _context) do
      send(Process.whereis(SpectreDirective.DirectiveActivityTest), {:publishing, self()})

      receive do
        :settle_publication -> publish("held")
      after
        5_000 -> {:error, :ambiguous, :publication_timed_out}
      end
    end

    def execute_effect(:publish, %{id: "uncertain"}, _context),
      do: {:error, :ambiguous, :publication_not_verified}

    def execute_effect(:publish, %{id: id}, _context) do
      publish(id)
    end

    defp publish(id) do
      send(Process.whereis(SpectreDirective.DirectiveActivityTest), {:published, id})
      {:ok, %{published: id}}
    end
  end

  defmodule AppActivity do
    use Spectre.Directive.Activity
    alias Spectre.Directive.ServerTool

    @impl Spectre.Directive.Activity
    def handle_invocation(invocation, result, ctx) do
      send(
        Process.whereis(SpectreDirective.DirectiveActivityTest),
        {:invocation, invocation, result}
      )

      assign(ctx, :summary, "Publication settled")
    end

    @impl Spectre.Activity
    def handle_signal(:inspect_handoff, ctx) do
      {:ok, state} = ServerTool.decode(ctx.assigns.directive_state)

      handoff =
        {ctx.assigns.directive_handoff, state.pending_request, state.working_context.last_result}

      send(Process.whereis(SpectreDirective.DirectiveActivityTest), {:handoff, handoff})
      ctx
    end

    def handle_signal(:finish, ctx), do: complete(ctx, %{result: ctx.assigns.summary})
    def handle_signal(signal, ctx), do: super(signal, ctx)
  end

  defmodule Stack do
    use Spectre.Stack

    install(Spectre.Directive)
    install(Documents)
    activity(:controlled, AppActivity)
  end

  defmodule Root do
    use Spectre.Server

    def handle_flow({:work, :mission}, %Spectre.Input{text: "mission " <> goal}, ctx),
      do: start_mission(ctx, goal, :autonomous)

    def handle_flow({:work, :guided}, %Spectre.Input{text: "guided " <> goal}, ctx),
      do: start_mission(ctx, goal, :guided)

    def handle_flow({:work, :controlled}, %Spectre.Input{text: "controlled " <> goal}, ctx),
      do: start_mission(ctx, goal, :autonomous, type: :controlled)

    def handle_flow({:work, :named}, %Spectre.Input{text: "named " <> goal}, ctx),
      do: start_mission(ctx, goal, :autonomous, as: :report)

    def handle_flow({:work, :ping}, _input, ctx), do: respond(ctx, "pong")
    def handle_flow(flow, input, ctx), do: super(flow, input, ctx)

    defp start_mission(ctx, goal, mode, opts \\ []) do
      {type, opts} = Keyword.pop(opts, :type, {:directive, :mission})

      start_activity(
        ctx,
        type,
        %{
          goal: goal,
          mode: mode,
          tools: %{"publish" => {:documents, :publish}},
          max_iterations: 12
        },
        Keyword.put(opts, :scope, [{:documents, :publish}])
      )
    end
  end

  defmodule Agent do
    use Spectre.Agent, stack: Stack, server: Root

    model(Model)
    router(strategies: [:regex])

    flow :work do
      on(:mission, regex: ~r/^mission .+/)
      on(:guided, regex: ~r/^guided .+/)
      on(:controlled, regex: ~r/^controlled .+/)
      on(:named, regex: ~r/^named .+/)
      on(:ping, regex: ~r/^ping$/)
    end
  end

  setup do
    Process.register(self(), __MODULE__)

    root =
      start_supervised!(
        {Server,
         agent: Agent,
         consumer: self(),
         identity: %{subject: Spectre.Identity.uuid7()},
         gam: [operations: %{publish: [class: @publication_class, confirm: true]}]}
      )

    %{root: root}
  end

  test "two missions run independently while the Root handles chat and GAM consent", %{root: root} do
    assert_chat(root)
    assert {:ok, []} = Server.activities(root)
    first = start_mission(root, "Publish the handbook")
    first_llm = inference("Publish the handbook")
    second = start_mission(root, "Summarize the roadmap")
    second_llm = inference("Summarize the roadmap")
    refute first == second

    assert_chat(root)

    decide(second_llm, %{kind: "complete_mission", result: "Roadmap summary"})
    assert completed(root, second) == "Roadmap summary"

    decide(first_llm, %{kind: "ask", question: "Which document should I publish?"})
    wait = input_wait(root, first, "Which document should I publish?")

    assert_chat(root)
    assert {:ok, %{status: :running}} = Server.activity(root, first)

    assert {:ok, _} = Server.input(root, "D12", activity: first, pending: wait)
    llm = inference("D12")
    decide(llm, %{kind: "invoke", target: "publish", args: %{id: "D12"}})

    presentation = present_publication(root, first)
    refute_received {:published, _}

    assert {:ok, _} = Server.decide(root, nil, presentation, :confirm)
    assert_receive {:published, "D12"}, @timeout

    llm = inference("succeeded")
    decide(llm, %{kind: "complete_mission", result: "Handbook published"})
    assert completed(root, first) == "Handbook published"

    assert {:ok, %{acts: acts, outcomes: outcomes}} = Server.gam_view(root)
    assert [%{ref: act}] = Enum.filter(acts, &(&1.class == @publication_class))
    assert [%{status: :succeeded}] = Enum.filter(outcomes, &(&1.act_ref == act))
    refute_received {:published, _}
  end

  test "a revision replaces a pending question and rejects its old reply", %{root: root} do
    ref = start_mission(root, "Prepare a report")
    decide(inference("Prepare a report"), %{kind: "ask", question: "Which month?"})
    old_wait = input_wait(root, ref, "Which month?")

    assert {:ok, signal} = Server.signal_activity(root, ref, {:revise, "Use November figures"})

    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:signalled, ^signal, {:ok, _}}}},
                   @timeout

    decide(inference("Use November figures"), %{kind: "ask", question: "Which region?"})
    new_wait = input_wait(root, ref, "Which region?")
    refute old_wait == new_wait
    assert {:error, _} = Server.input(root, "October", activity: ref, pending: old_wait)
    assert {:ok, _} = Server.input(root, "Italy", activity: ref, pending: new_wait)

    decide(inference("Italy"), %{kind: "complete_mission", result: "November in Italy"})
    assert completed(root, ref) == "November in Italy"
  end

  test "a model can only invoke aliases supplied to its mission", %{root: root} do
    ref = start_mission(root, "Read the archive")

    decide(inference("Read the archive"), %{
      kind: "invoke",
      target: "documents.publish",
      args: %{id: "D12"}
    })

    decide(inference("unknown_mission_tool"), %{kind: "complete_mission", result: "Unavailable"})
    assert completed(root, ref) == "Unavailable"

    refute_received {Managed, _, {:presentation, _}}
    refute_received {:published, _}
    assert_chat(root)
  end

  test "repeated unknown aliases consume the mission's reasoning budget", %{root: root} do
    ref = start_mission(root, "Attempt a publish")
    invalid = %{kind: "invoke", target: "external_tool", args: %{}}

    decide(inference("Attempt a publish"), invalid)
    for _ <- 1..5, do: decide(inference("unknown_mission_tool"), invalid)

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref}, {:failed, {:max_iterations_exceeded, 12}}}},
                   @timeout

    refute_received {Managed, _, {:presentation, _}}
    refute_received {:published, _}
  end

  test "a tool preparation rejection informs Directive without handing off", %{root: root} do
    ref = start_mission(root, "Publish with the correct identifier", "controlled")

    decide(inference("Publish with the correct identifier"), %{
      kind: "invoke",
      target: "publish",
      args: %{}
    })

    decide(inference("invalid_publish_arguments"), %{
      kind: "complete_mission",
      result: "Missing ID"
    })

    assert completed(root, ref) == "Missing ID"
    refute_received {:invocation, _, _}
    refute_received {Managed, _, {:presentation, _}}
  end

  test "an application consumes a correlated result and keeps control after revision", %{
    root: root
  } do
    ref = start_mission(root, "Publish through the application", "controlled")

    decide(inference("Publish through the application"), %{
      kind: "invoke",
      target: "publish",
      args: %{id: "D12"}
    })

    presentation = present_publication(root, ref)
    assert {:ok, _} = Server.decide(root, nil, presentation, :confirm)
    assert_receive {:published, "D12"}, @timeout

    assert_receive {:invocation,
                    %{
                      request_id: request,
                      tool: {:documents, :publish},
                      args: %{"id" => "D12"},
                      plan_version: version
                    },
                    {:governed,
                     %{
                       act: %{consequence: %{"payload" => %{id: "D12"}}},
                       outcome: %{status: :succeeded}
                     }}},
                   @timeout

    assert is_binary(request)
    assert version > 0
    assert_handoff(root, ref, request, version)
    assert {:ok, signal} = Server.signal_activity(root, ref, {:revise, "Later instructions"})

    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:signalled, ^signal, {:ok, _}}}},
                   @timeout

    assert_handoff(root, ref, request, version)

    assert {:ok, _} = Server.signal_activity(root, ref, :finish)
    assert completed(root, ref) == "Publication settled"
    refute_received {:infer, _, _}
    refute_received {:published, _}
  end

  test "an ambiguous outcome fails for reconciliation before calling the application", %{
    root: root
  } do
    ref = start_mission(root, "Publish once", "controlled")

    decide(inference("Publish once"), %{
      kind: "invoke",
      target: "publish",
      args: %{id: "uncertain"}
    })

    assert {:ok, _} = Server.decide(root, nil, present_publication(root, ref), :confirm)

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref},
                     {:failed, {:unconfirmed_tool, %{status: :ambiguous}}}}},
                   @timeout

    refute_received {:invocation, _, _}
    refute_received {:infer, _, _}
  end

  test "a guided plan needs an addressed reply before it can start its steps", %{root: root} do
    ref = start_mission(root, "Review the handbook", "guided")

    decide(inference("Review the handbook"), %{
      kind: "propose_plan",
      plan: [%{id: "review", title: "Read the handbook"}]
    })

    wait = input_wait(root, ref, "Approve this mission plan change?")
    assert_chat(root)
    refute_received {:infer, _, _}

    assert {:ok, _} = Server.input(root, "yes", activity: ref, pending: wait)
    decide(inference("Read the handbook"), %{kind: "complete_step", result: "Reviewed"})
    decide(inference("Reviewed"), %{kind: "complete_mission", result: "Handbook reviewed"})
    assert completed(root, ref) == "Handbook reviewed"
  end

  test "a malformed decision fails its mission while a sibling and the Root keep running", %{
    root: root
  } do
    ref = start_mission(root, "Build a draft")
    failed_model = inference("Build a draft")
    sibling = start_mission(root, "Summarize the evidence")
    surviving_model = inference("Summarize the evidence")

    decide(failed_model, "Expected a decision object")

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref}, {:failed, :invalid_mission_decision}}},
                   @timeout

    assert_chat(root)
    decide(surviving_model, %{kind: "complete_mission", result: "Evidence summarized"})
    assert completed(root, sibling) == "Evidence summarized"
  end

  test "a reused key leaves the old lifecycle identity and control target intact", %{root: root} do
    first = start_mission(root, "Report for October", "named")

    decide(inference("Report for October"), %{kind: "complete_mission", result: "October"})

    assert_receive {Server, ^root, {:activity, identity, {:completed, %{result: "October"}}}},
                   @timeout

    # The application can process this completion after it has started the next report.
    second = start_mission(root, "Report for November", "named")
    november = inference("Report for November")
    assert %{ref: ^first, key: :report} = identity
    refute first == second
    assert {:ok, %{ref: ^second, status: :running}} = Server.activity(root, :report)

    assert {:ok, signal} = Server.signal_activity(root, first, {:revise, "Late change"})

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^first, key: :report},
                     {:signalled, ^signal, {:error, :inactive_activity}}}},
                   @timeout

    decide(november, %{kind: "complete_mission", result: "November"})
    assert completed(root, second) == "November"
  end

  test "a revision cannot replay a prior governed invocation", %{root: root} do
    ref = start_mission(root, "Publish the briefing")
    decision = %{kind: "invoke", target: "publish", args: %{id: "held"}}
    decide(inference("Publish the briefing"), decision)
    presentation = present_publication(root, ref)
    assert {:ok, _} = Server.decide(root, nil, presentation, :confirm)
    assert_receive {:publishing, executor}, @timeout
    on_exit(fn -> send(executor, :settle_publication) end)

    assert {:ok, signal} =
             Server.signal_activity(root, ref, {:revise, "Check the latest version"})

    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:signalled, ^signal, {:ok, _}}}},
                   @timeout

    llm = inference("Check the latest version")
    send(executor, :settle_publication)
    assert_receive {:published, "held"}, @timeout

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref},
                     {:effect, {:governed, %{outcome: %{status: :succeeded}}}}}},
                   @timeout

    observed_llm = inference("succeeded")
    decide(llm, %{kind: "complete_mission", result: "Stale model output"})
    decide(observed_llm, decision)

    decide(inference("superseded_invocation_requires_reconciliation"), %{
      kind: "complete_mission",
      result: "The original publication is already recorded"
    })

    assert completed(root, ref) == "The original publication is already recorded"

    refute_received {:publishing, _}
    refute_received {Managed, _, {:presentation, _}}
    assert_chat(root)
  end

  defp present_publication(root, ref) do
    assert_receive {Managed, _, {:presentation, %{"presentation_ref" => presentation}}}, @timeout
    assert :ok = Server.presented(root, presentation)
    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:pending, ^presentation}}}, @timeout
    presentation
  end

  defp start_mission(root, goal, verb \\ "mission") do
    assert {:ok, _} = Server.input(root, "#{verb} #{goal}")
    assert_receive {Server, ^root, {:activity, %{ref: ref}, :started}}, @timeout
    ref
  end

  defp inference(expected) do
    assert_receive {:infer, pid, prompt}, @timeout
    assert is_binary(prompt)
    assert prompt =~ "DIRECTIVE_INPUT_JSON:"
    assert prompt =~ expected
    pid
  end

  defp decide(pid, decision), do: send(pid, {:decision, decision})

  defp input_wait(root, ref, expected_prompt) do
    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref},
                     {:waiting_input, %{id: id, revision: revision, prompt: prompt}}}},
                   @timeout

    assert prompt =~ expected_prompt
    {id, revision}
  end

  defp assert_handoff(root, ref, request, version) do
    assert {:ok, _} = Server.signal_activity(root, ref, :inspect_handoff)

    assert_receive {:handoff,
                    {%{request_id: ^request, plan_version: ^version}, nil, %{status: :succeeded}}},
                   @timeout
  end

  defp assert_chat(root) do
    assert {:ok, turn} = Server.input(root, "ping")
    assert_receive {Server, ^root, {:response, ^turn, "pong", _}}, @timeout
  end

  defp completed(root, ref) do
    assert_receive {Server, ^root, {:activity, %{ref: ^ref}, {:completed, %{result: result}}}},
                   @timeout

    result
  end
end
