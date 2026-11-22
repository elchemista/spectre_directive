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

    def execute_effect(:publish, %{id: id}, _context) do
      publish(id)
    end

    defp publish(id) do
      send(Process.whereis(SpectreDirective.DirectiveActivityTest), {:published, id})
      {:ok, %{published: id}}
    end
  end

  defmodule Stack do
    use Spectre.Stack

    install(Spectre.Directive)
    install(Documents)
  end

  defmodule Root do
    use Spectre.Server

    def handle_flow({:work, :mission}, %Spectre.Input{text: "mission " <> goal}, ctx),
      do: start_mission(ctx, goal, :autonomous)

    def handle_flow({:work, :guided}, %Spectre.Input{text: "guided " <> goal}, ctx),
      do: start_mission(ctx, goal, :guided)

    def handle_flow({:work, :ping}, _input, ctx), do: respond(ctx, "pong")
    def handle_flow(flow, input, ctx), do: super(flow, input, ctx)

    defp start_mission(ctx, goal, mode) do
      start_activity(
        ctx,
        {:directive, :mission},
        %{goal: goal, mode: mode, tools: %{"publish" => {:documents, :publish}}},
        scope: [{:documents, :publish}]
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

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref},
                     {:failed, {:unknown_mission_tool, "documents.publish"}}}},
                   @timeout

    refute_received {Managed, _, {:presentation, _}}
    refute_received {:published, _}
    assert_chat(root)
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

  test "a malformed model decision fails its mission and leaves the Root available", %{root: root} do
    ref = start_mission(root, "Build a draft")
    decide(inference("Build a draft"), "Expected a decision object")

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref}, {:failed, :invalid_mission_decision}}},
                   @timeout

    assert_chat(root)
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

    assert_receive {Server, ^root,
                    {:activity, %{ref: ^ref},
                     {:failed, :superseded_invocation_requires_reconciliation}}},
                   @timeout

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
