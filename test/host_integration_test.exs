defmodule SpectreDirective.IntegratedGenServer do
  use GenServer
  use Spectre.Directive

  directive "manual" do
    mission("Complete inside a GenServer host")
    mode(:fixed)
    step("Decide")
  end

  def start_link(owner, opts \\ []) do
    GenServer.start_link(__MODULE__, owner, opts)
  end

  @impl GenServer
  def init(owner), do: {:ok, %{owner: owner, events: []}}

  @impl Spectre.Directive.Handler
  def handle_directive({event, mission_id, payload}, state) do
    send(state.owner, {:gen_server_directive, self(), event, mission_id, payload})
    {:noreply, %{state | events: [{event, mission_id} | state.events]}}
  end

  def handle_directive(message, state), do: super(message, state)
end

defmodule SpectreDirective.CustomInfoGenServer do
  use GenServer

  @impl GenServer
  def handle_info({:spectre_directive, _mission_id, _event, _payload} = message, state),
    do: directive_handle_info(message, state)

  def handle_info({:custom, owner}, state) do
    send(owner, :custom_info_handled)
    {:noreply, state}
  end

  use Spectre.Directive, gen_server_handler: false

  directive "custom" do
    mission("Use a custom handle_info")
    mode(:fixed)
    step("Wait")
  end

  @impl GenServer
  def init(owner), do: {:ok, owner}

  @impl Spectre.Directive.Handler
  def handle_directive({event, mission_id, payload}, owner) do
    send(owner, {:custom_directive, event, mission_id, payload})
    {:noreply, owner}
  end

  def handle_directive(message, state), do: super(message, state)
end

defmodule SpectreDirective.CustomCompilerGenServer do
  use GenServer

  def start_directive(server, name), do: {:custom_start, server, name}
  def start_directive(server, name, opts), do: {:custom_start, server, name, opts}
  def directive_handle_info(message, state), do: {:custom_info, message, state}

  use Spectre.Directive

  directive "custom-api" do
    mission("Keep custom compiler APIs")
  end

  @impl GenServer
  def init(state), do: {:ok, state}
end

defmodule SpectreDirective.BadVia do
  def whereis_name(_name), do: raise("bad via")
end

defmodule SpectreDirective.ResolverHost do
  def handle_directive({:invocation, "function"}, _context), do: {:ok, fn _ -> :ok end}
  def handle_directive({:invocation, "module"}, _context), do: String
  def handle_directive({:invocation, "mfa"}, _context), do: {String, :upcase}
  def handle_directive({:invocation, "mfa_args"}, _context), do: {String, :replace, ["a", "b"]}
  def handle_directive({:invocation, "error"}, _context), do: {:error, :denied}
  def handle_directive({:invocation, "bad"}, _context), do: "still symbolic"
  def handle_directive({:invocation, "raise"}, _context), do: raise("resolver failed")
  def handle_directive({:invocation, target}, _context), do: target
end

defmodule SpectreDirective.IntegratedSpectreAgent do
  use Spectre.Agent
  use Spectre.Directive

  directive "agent" do
    mission("Complete through a real Spectre Agent")
    mode(:autonomous)
  end

  @impl Spectre.Directive.Handler
  def handle_directive({:reason, %SpectreDirective.Context{operation: :plan}}, _spectre_context) do
    {:propose_plan, [%{title: "Run trusted function", invoke: "finish"}]}
  end

  def handle_directive(
        {:reason, %SpectreDirective.Context{operation: :mission_review}},
        _spectre_context
      ) do
    {:complete_mission, :spectre_agent_done}
  end

  def handle_directive({:invocation, "finish"}, _context) do
    {:ok, fn _context -> {:complete_step, :trusted_function_ran} end}
  end

  def handle_directive(message, context), do: super(message, context)
end

defmodule SpectreDirective.DefaultReasonSpectreAgent do
  use Spectre.Agent
  use Spectre.Directive

  directive "default-reason" do
    mission("Use the Agent model boundary")
    mode(:autonomous)
  end

  @impl Spectre.Directive.Handler
  def handle_directive({:invocation, "finish"}, _context) do
    fn _context -> {:complete_step, :default_model_invoked} end
  end

  def handle_directive(message, context), do: super(message, context)
end

defmodule SpectreDirective.HostIntegrationTest do
  use ExUnit.Case, async: false

  alias SpectreDirective.AgentDecision
  alias SpectreDirective.Integration
  alias SpectreDirective.Integration.GenServer, as: GenServerIntegration
  alias SpectreDirective.Integration.SpectreAgent
  alias SpectreDirective.Integration.SpectreAgent.Codec
  alias SpectreDirective.Integration.SpectreAgent.DecisionResolver
  alias SpectreDirective.Integration.SpectreAgent.Prompt
  alias SpectreDirective.Invocation
  alias SpectreDirective.Loop.Engine
  alias SpectreDirective.Outcome
  alias SpectreDirective.Plan
  alias SpectreDirective.PlanPatch
  alias SpectreDirective.Request

  setup_all do
    SpectreDirective.Runtime.Supervisor.ensure_started()

    case Registry.start_link(keys: :unique, name: SpectreDirective.TestViaRegistry) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  describe "native GenServer integration" do
    test "generated API subscribes the GenServer and dispatches requests and outcome" do
      assert SpectreDirective.IntegratedGenServer.__spectre_directive_host__() == :gen_server
      assert {:ok, server} = SpectreDirective.IntegratedGenServer.start_link(self())

      assert {:ok, mission} =
               SpectreDirective.IntegratedGenServer.start_directive(server, "manual",
                 execution: :manual
               )

      on_exit(fn ->
        safe_stop(mission)
        safe_exit(server)
      end)

      assert_receive {:gen_server_directive, ^server, :request, mission_id,
                      %Request{kind: :reason} = request},
                     1_000

      assert {:ok, _pulse} =
               Spectre.Directive.respond(
                 mission,
                 request.id,
                 {:complete_mission, :gen_server_done}
               )

      assert_receive {:gen_server_directive, ^server, :outcome, ^mission_id,
                      %Outcome{result: :gen_server_done}},
                     1_000

      # Directive state remains owned by the host process; no extra handle_call API is required.
      %{events: events} = :sys.get_state(server)
      assert Enum.any?(events, fn {event, _id} -> event == :request end)
      assert Enum.any?(events, fn {event, _id} -> event == :outcome end)
    end

    test "supports local names, globals, via registries, and existing subscribers" do
      local_name = SpectreDirective.NamedDirectiveHost

      assert {:ok, local} =
               SpectreDirective.IntegratedGenServer.start_link(self(), name: local_name)

      global_name = {:directive_host, make_ref()}

      assert {:ok, global} =
               SpectreDirective.IntegratedGenServer.start_link(self(),
                 name: {:global, global_name}
               )

      via_name = {:directive_host, make_ref()}

      assert {:ok, via} =
               SpectreDirective.IntegratedGenServer.start_link(self(),
                 name: {:via, Registry, {SpectreDirective.TestViaRegistry, via_name}}
               )

      on_exit(fn -> Enum.each([local, global, via], &safe_exit/1) end)

      servers = [
        local_name,
        {:global, global_name},
        {:via, Registry, {SpectreDirective.TestViaRegistry, via_name}}
      ]

      missions =
        Enum.map(servers, fn server ->
          assert {:ok, mission} =
                   SpectreDirective.IntegratedGenServer.start_directive(server, "manual",
                     execution: :manual,
                     subscribers: [self(), self()]
                   )

          mission
        end)

      on_exit(fn -> Enum.each(missions, &safe_stop/1) end)

      Enum.each(missions, fn mission ->
        assert {:ok, %Request{}} = wait_for_request(mission)
        assert {:ok, _pulse} = Spectre.Directive.cancel(mission)
      end)
    end

    test "returns precise errors for dead, missing, invalid, and failing server references" do
      dead = spawn(fn -> :ok end)
      monitor = Process.monitor(dead)
      assert_receive {:DOWN, ^monitor, :process, ^dead, reason}, 1_000
      assert reason in [:normal, :noproc]

      assert {:error, {:gen_server_not_alive, ^dead}} =
               GenServerIntegration.start(SpectreDirective.IntegratedGenServer, dead, "manual")

      assert {:error, {:gen_server_not_found, :missing_directive_server}} =
               GenServerIntegration.start(
                 SpectreDirective.IntegratedGenServer,
                 :missing_directive_server,
                 "manual"
               )

      missing_global = {:global, {:missing, make_ref()}}

      assert {:error, {:gen_server_not_found, ^missing_global}} =
               GenServerIntegration.start(
                 SpectreDirective.IntegratedGenServer,
                 missing_global,
                 "manual"
               )

      missing_via = {:via, Registry, {SpectreDirective.TestViaRegistry, make_ref()}}

      assert {:error, {:gen_server_not_found, ^missing_via}} =
               GenServerIntegration.start(
                 SpectreDirective.IntegratedGenServer,
                 missing_via,
                 "manual"
               )

      bad_via = {:via, SpectreDirective.BadVia, :name}

      assert {:error, {:invalid_gen_server, ^bad_via, %RuntimeError{}}} =
               GenServerIntegration.start(
                 SpectreDirective.IntegratedGenServer,
                 bad_via,
                 "manual"
               )

      assert {:error, {:invalid_gen_server, {:bad, :server}}} =
               GenServerIntegration.start(
                 SpectreDirective.IntegratedGenServer,
                 {:bad, :server},
                 "manual"
               )
    end

    test "custom handle_info routing and custom generated APIs remain reachable" do
      assert {:ok, server} = GenServer.start_link(SpectreDirective.CustomInfoGenServer, self())
      send(server, {:custom, self()})
      assert_receive :custom_info_handled, 1_000

      assert {:ok, mission} =
               SpectreDirective.CustomInfoGenServer.start_directive(server, "custom",
                 execution: :manual
               )

      on_exit(fn ->
        safe_stop(mission)
        safe_exit(server)
      end)

      assert_receive {:custom_directive, :request, mission_id, %Request{}}, 1_000
      assert is_binary(mission_id)
      assert {:ok, _pulse} = Spectre.Directive.cancel(mission)

      assert SpectreDirective.CustomCompilerGenServer.start_directive(:server, :name) ==
               {:custom_start, :server, :name}

      assert SpectreDirective.CustomCompilerGenServer.start_directive(:server, :name, a: 1) ==
               {:custom_start, :server, :name, [a: 1]}

      assert SpectreDirective.CustomCompilerGenServer.directive_handle_info(:message, :state) ==
               {:custom_info, :message, :state}
    end

    test "bridge fallback and default host callback preserve application state" do
      assert GenServerIntegration.handle_info(String, :unrelated, %{state: 1}) ==
               {:noreply, %{state: 1}}

      assert Integration.handle(String, :gen_server, {:request, "mission", :payload}, :state) ==
               {:noreply, :state}

      assert Integration.handle(String, :standalone, :message, :context) ==
               {:error, {:unsupported_directive_message, :standalone, :message, :context}}
    end
  end

  describe "real Spectre Agent integration" do
    test "Agent private route reasons, resolves a symbolic invocation, and completes" do
      assert SpectreDirective.IntegratedSpectreAgent.__spectre_directive_host__() ==
               :spectre_agent

      assert function_exported?(
               SpectreDirective.IntegratedSpectreAgent,
               :__spectre_directive_reason__,
               2
             )

      assert {:ok, mission} = SpectreDirective.IntegratedSpectreAgent.start_directive("agent")
      on_exit(fn -> safe_stop(mission) end)

      assert {:ok, %Outcome{status: :completed, result: :spectre_agent_done}} =
               Spectre.Directive.await(mission, 3_000)

      assert {:ok, state} = Spectre.Directive.state(mission)

      assert Enum.any?(state.working_context.information, fn information ->
               information.content == :trusted_function_ran
             end)
    end

    test "default Agent reasoning uses its model options, JSON codec, and host trust boundary" do
      model = fn prompt, _opts ->
        response =
          cond do
            String.contains?(prompt, ~s("operation":"plan")) ->
              %{
                kind: "propose_plan",
                plan: [%{title: "Finish", invoke: "finish"}]
              }

            String.contains?(prompt, ~s("operation":"mission_review")) ->
              %{kind: "complete_mission", result: "default_reason_done"}

            true ->
              %{kind: "blocked", reason: "unexpected operation"}
          end

        {:ok, Jason.encode!(response)}
      end

      assert {:ok, mission} =
               SpectreDirective.DefaultReasonSpectreAgent.start_directive("default-reason",
                 spectre_opts: [model: model]
               )

      on_exit(fn -> safe_stop(mission) end)

      assert {:ok, %Outcome{result: "default_reason_done"}} =
               Spectre.Directive.await(mission, 3_000)

      assert {:ok, state} = Spectre.Directive.state(mission)

      assert Enum.any?(state.working_context.information, fn information ->
               information.content == :default_model_invoked
             end)
    end

    test "Agent start validates the optional dependency and required owner" do
      assert {:error, {:spectre_agent_reasoning_failed, :spectre_agent_required}} =
               SpectreAgent.decide(context(), agent: nil, owner: SpectreDirective.ResolverHost)

      assert {:error, {:spectre_agent_reasoning_failed, :directive_owner_required}} =
               SpectreAgent.decide(context(), agent: SpectreDirective.IntegratedSpectreAgent)
    end
  end

  describe "Spectre codec, prompt, and decision trust boundary" do
    test "codec makes structs, tuples, atoms, dates, keys, and opaque terms JSON-safe" do
      value = %{
        7 => self(),
        atom: :value,
        date: ~U[2026-01-01 00:00:00Z],
        struct: context().mission,
        tuple: {:ok, 1},
        list: [:a, true, nil, 1.5]
      }

      assert {:ok, encoded} = Codec.encode(value)
      assert {:ok, decoded} = Jason.decode(encoded)
      assert decoded["atom"] == "value"
      assert decoded["date"] == "2026-01-01T00:00:00Z"
      assert decoded["tuple"] == ["ok", 1]
      assert decoded["7"] =~ "#PID"
      assert decoded["struct"]["__struct__"] == "SpectreDirective.Mission"

      assert Codec.decode(~s|```json\n{"kind":"ask"}\n```|) ==
               {:ok, %{"kind" => "ask"}}

      assert Codec.decode(~s|prefix {"kind":"blocked"} suffix|) ==
               {:ok, %{"kind" => "blocked"}}

      assert {:error, %Jason.DecodeError{}} = Codec.decode("not json")
      assert Codec.decode(:not_text) == {:error, {:expected_json_response, :not_text}}
    end

    test "prompt contains the provider-neutral protocol and safe context" do
      assert {:ok, prompt} = Prompt.build(context())
      assert prompt =~ "Return exactly one JSON object"
      assert prompt =~ "DIRECTIVE_INPUT_JSON"
      assert prompt =~ "Codec mission"
      assert prompt =~ "propose_patch"
    end

    test "trusted invocation accepts executable shapes and rejects symbolic or malformed values" do
      function = fn _ -> :ok end
      assert DecisionResolver.trusted_invocation(function) == {:ok, function}
      assert DecisionResolver.trusted_invocation(String) == {:ok, String}
      assert DecisionResolver.trusted_invocation({String, []}) == {:ok, {String, []}}
      assert DecisionResolver.trusted_invocation({String, :upcase}) == {:ok, {String, :upcase}}

      assert DecisionResolver.trusted_invocation({String, :replace, ["a", "b"]}) ==
               {:ok, {String, :replace, ["a", "b"]}}

      assert DecisionResolver.trusted_invocation(nil) ==
               {:error, {:unresolved_directive_invocation, nil}}

      assert DecisionResolver.trusted_invocation("symbolic") ==
               {:error, {:unresolved_directive_invocation, "symbolic"}}

      assert DecisionResolver.trusted_invocation({String, "bad"}) ==
               {:error, {:unresolved_directive_invocation, {String, "bad"}}}
    end

    test "resolves direct and policy invocations through the host" do
      context = context()

      assert {:ok, invoke} = AgentDecision.new({:invoke, "function"})

      assert {:ok, resolved} =
               DecisionResolver.resolve(SpectreDirective.ResolverHost, invoke, context)

      assert is_function(resolved.invocation.target, 1)

      assert {:ok, policy} = AgentDecision.new({:ask_policy, :safe, "mfa"})

      assert {:ok, policy} =
               DecisionResolver.resolve(SpectreDirective.ResolverHost, policy, context)

      assert policy.invocation.target == {String, :upcase}

      assert {:ok, no_invocation} = AgentDecision.new({:ask_policy, :safe})

      assert DecisionResolver.resolve(SpectreDirective.ResolverHost, no_invocation, context) ==
               {:ok, no_invocation}

      assert {:ok, missing} = AgentDecision.new(%{kind: :invoke})

      assert DecisionResolver.resolve(SpectreDirective.ResolverHost, missing, context) ==
               {:error, :invocation_required}

      assert {:ok, denied} = AgentDecision.new({:invoke, "error"})

      assert DecisionResolver.resolve(SpectreDirective.ResolverHost, denied, context) ==
               {:error, :denied}

      assert {:ok, bad} = AgentDecision.new({:invoke, "bad"})

      assert DecisionResolver.resolve(SpectreDirective.ResolverHost, bad, context) ==
               {:error, {:unresolved_directive_invocation, "still symbolic"}}

      assert {:ok, raising} = AgentDecision.new({:invoke, "raise"})

      assert {:error, {:invocation_handler_failed, RuntimeError, "resolver failed"}} =
               DecisionResolver.resolve(SpectreDirective.ResolverHost, raising, context)
    end

    test "resolves generated plans in every accepted representation" do
      context = context()

      values = [
        [%{title: "One", invoke: "function"}, %{title: "No invocation"}],
        %{steps: [%{title: "One", invoke: %{name: "module", policy: :safe}}]},
        %{"steps" => [%{"title" => "One", "invoke" => %{"target" => "mfa_args"}}]},
        Plan.new([%{title: "One", invoke: Invocation.new("mfa")}])
      ]

      Enum.each(values, fn value ->
        decision = %AgentDecision{kind: :propose_plan, plan: value}

        assert {:ok, resolved} =
                 DecisionResolver.resolve(SpectreDirective.ResolverHost, decision, context)

        assert %Plan{} = resolved.plan
        assert hd(resolved.plan.steps).invoke != nil
      end)

      invalid = %AgentDecision{kind: :propose_plan, plan: :bad}

      assert DecisionResolver.resolve(SpectreDirective.ResolverHost, invalid, context) ==
               {:error, {:invalid_generated_plan, :bad}}

      malformed = %AgentDecision{kind: :propose_plan, plan: %{steps: :bad}}

      assert {:error, {:invalid_generated_plan, _error}} =
               DecisionResolver.resolve(SpectreDirective.ResolverHost, malformed, context)
    end

    test "resolves invocation-bearing add, insert, and replace patch operations" do
      patch =
        PlanPatch.new(%{
          operations: [
            {:add, %{title: "Add", invoke: "function"}},
            {:insert_after, "one", %{title: "Insert", invoke: %{target: "module"}}},
            {:replace, "one", %{title: "Replace", invoke: Invocation.new("mfa")}},
            {:remove, "old"}
          ]
        })

      decision = %AgentDecision{kind: :propose_patch, patch: patch}

      assert {:ok, resolved} =
               DecisionResolver.resolve(SpectreDirective.ResolverHost, decision, context())

      assert %PlanPatch{} = resolved.patch

      assert [
               {:add, add},
               {:insert_after, "one", insert},
               {:replace, "one", replace},
               {:remove, "old"}
             ] =
               resolved.patch.operations

      assert %Invocation{} = add.invoke
      assert %Invocation{} = insert.invoke
      assert %Invocation{} = replace.invoke

      malformed = %AgentDecision{kind: :propose_patch, patch: %{metadata: :bad}}

      assert {:error, {:invalid_generated_patch, _error}} =
               DecisionResolver.resolve(SpectreDirective.ResolverHost, malformed, context())

      passthrough = %AgentDecision{kind: :ask, question: "Question"}

      assert DecisionResolver.resolve(SpectreDirective.ResolverHost, passthrough, context()) ==
               {:ok, passthrough}
    end
  end

  describe "compile-time host validation" do
    test "rejects forced or late hosts and duplicate private Agent rules" do
      assert_compile_error("host :spectre_agent requires use Spectre.Agent", """
      defmodule ForcedAgentWithoutSpectre do
        use Spectre.Directive, host: :spectre_agent
      end
      """)

      assert_compile_error("host :gen_server requires use GenServer", """
      defmodule ForcedGenServerWithoutBehaviour do
        use Spectre.Directive, host: :gen_server
      end
      """)

      assert_compile_error("use GenServer must appear before use Spectre.Directive", """
      defmodule LateDirectiveGenServer do
        use Spectre.Directive
        use GenServer
        def init(state), do: {:ok, state}
      end
      """)

      assert_compile_error("use Spectre.Agent must appear before use Spectre.Directive", """
      defmodule LateDirectiveSpectreAgent do
        use Spectre.Directive
        use Spectre.Agent
      end
      """)

      assert_compile_error("already defines :__spectre_directive_reason__", """
      defmodule DuplicateDirectiveRuleAgent do
        use Spectre.Agent
        @spectre_rules %{label: :__spectre_directive_reason__}
        use Spectre.Directive
      end
      """)
    end

    test "host aliases compile when their required DSL is already installed" do
      agent = Module.concat(__MODULE__, :AliasAgent)
      server = Module.concat(__MODULE__, :AliasServer)

      Code.compile_string("""
      defmodule #{inspect(agent)} do
        use Spectre.Agent
        use Spectre.Directive, host: :spectre
      end

      defmodule #{inspect(server)} do
        use GenServer
        use Spectre.Directive, host: :genserver
        @impl true
        def init(state), do: {:ok, state}
      end
      """)

      assert agent.__spectre_directive_host__() == :spectre_agent
      assert server.__spectre_directive_host__() == :gen_server
      assert Integration.marker() == "__spectre_directive_reason__"

      assert Integration.handle(agent, :spectre_agent, {:invocation, String}, context()) ==
               {:ok, String}
    end
  end

  defp context do
    {:ok, loop} = Engine.new(mission: "Codec mission", steps: [%{title: "Codec step"}])
    {:request, request, _loop} = Engine.next(loop)
    request.context
  end

  defp wait_for_request(mission, attempts \\ 100)
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

  defp assert_compile_error(message, source) do
    assert_raise ArgumentError, ~r/#{Regex.escape(message)}/, fn ->
      Code.compile_string(source)
    end
  end

  defp safe_stop(mission) when is_pid(mission) do
    if Process.alive?(mission), do: Spectre.Directive.stop(mission), else: :ok
  end

  defp safe_exit(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid), else: :ok
  end
end
