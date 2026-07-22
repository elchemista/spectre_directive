defmodule SpectreDirective do
  @moduledoc """
  Embeddable, self-correcting mission and plan loop.

  The pure API emits correlated requests and applies responses without running
  application code:

      {:ok, loop} = SpectreDirective.new(mission: "Research the client")
      {:request, request, loop} = SpectreDirective.next(loop)
      {:request, next_request, loop} =
        SpectreDirective.respond(loop, request.id, {:propose_plan, steps})

  The optional OTP runtime can execute configured reasoners and invocation
  targets in supervised tasks, or leave every request to the host:

      {:ok, mission} =
        SpectreDirective.start_mission("Research the client",
          reasoner: MyApp.Agent,
          execution: :auto,
          subscribers: [self()]
        )

  For authored directives, prefer the public Spectre-shaped entry point:

      defmodule MyApp.ClientResearch do
        use Spectre.Directive

        directive "client-research" do
          mission "Research the client"
        end
      end
  """

  alias SpectreDirective.DSL.Builder
  alias SpectreDirective.Integration
  alias SpectreDirective.Loop.Engine
  alias SpectreDirective.Loop.State, as: LoopState
  alias SpectreDirective.Mission
  alias SpectreDirective.MissionBlueprint
  alias SpectreDirective.Runtime.MissionProcesses

  @type mission_ref :: pid() | binary()
  @type runtime_result(value) :: {:ok, value} | {:error, term()}

  @doc "Imports the authored Directive DSL and installs the detected host integration."
  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(opts) do
    opts = evaluate_use_options(opts, __CALLER__)

    quote bind_quoted: [opts: opts] do
      import SpectreDirective.DSL

      Builder.register(__MODULE__)
      Integration.register(__MODULE__, opts)
      @before_compile SpectreDirective.DSL
    end
  end

  @doc "Returns the optional runtime supervisor child specification."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: SpectreDirective.Runtime.Supervisor.child_spec(opts)

  @doc "Starts the optional local runtime supervision tree."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []), do: SpectreDirective.Runtime.Supervisor.start_link(opts)

  @doc "Creates pure loop state. No process or callback is started."
  @spec new(map() | keyword()) :: {:ok, LoopState.t()} | {:error, term()}
  def new(attrs), do: Engine.new(attrs)

  @doc "Projects callback context into data without executable invocation targets."
  @spec context_map(SpectreDirective.Context.t()) :: map()
  def context_map(%SpectreDirective.Context{} = context),
    do: SpectreDirective.Context.to_map(context)

  @doc "Builds a provider-neutral LLM payload from callback context."
  @spec reasoning_input(SpectreDirective.Context.t()) :: map()
  def reasoning_input(%SpectreDirective.Context{} = context) do
    %{protocol: SpectreDirective.Protocol.describe(), context: context_map(context)}
  end

  @doc "Returns the provider-neutral decision protocol."
  @spec protocol() :: map()
  def protocol, do: SpectreDirective.Protocol.describe()

  @doc "Advances a pure loop to its next request, boundary, or outcome."
  @spec next(LoopState.t()) :: Engine.next_result()
  def next(%LoopState{} = state), do: Engine.next(state)

  @doc "Applies a correlated response to a pure loop or live mission."
  @spec respond(LoopState.t() | mission_ref(), binary(), term()) ::
          Engine.result() | runtime_result(SpectreDirective.Pulse.t())
  def respond(%LoopState{} = state, request_id, response),
    do: Engine.respond(state, request_id, response)

  def respond(ref, request_id, response), do: MissionProcesses.respond(ref, request_id, response)

  @doc "Responds to the current pending request of a live mission."
  @spec respond(mission_ref(), term()) :: runtime_result(SpectreDirective.Pulse.t())
  def respond(ref, response), do: MissionProcesses.respond(ref, response)

  @doc "Adds mission-local information without implicitly completing a request."
  @spec inform(LoopState.t() | mission_ref(), term(), keyword()) ::
          {:ok, LoopState.t()} | runtime_result(SpectreDirective.Pulse.t()) | {:error, term()}
  def inform(state_or_ref, information, opts \\ [])

  def inform(%LoopState{} = state, information, opts), do: Engine.inform(state, information, opts)
  def inform(ref, information, opts), do: MissionProcesses.inform(ref, information, opts)

  @doc "Merges application-owned assigns into pure or live mission context."
  @spec assign(LoopState.t() | mission_ref(), map()) ::
          {:ok, LoopState.t()} | runtime_result(SpectreDirective.Pulse.t()) | {:error, term()}
  def assign(%LoopState{} = state, assigns), do: Engine.assign(state, assigns)
  def assign(ref, assigns), do: MissionProcesses.assign(ref, assigns)

  @doc "Pauses pure loop state or a live mission."
  @spec pause(LoopState.t() | mission_ref()) ::
          {:ok, LoopState.t()} | runtime_result(SpectreDirective.Pulse.t()) | {:error, term()}
  def pause(%LoopState{} = state), do: Engine.pause(state)
  def pause(ref), do: MissionProcesses.control(ref, :pause)

  @doc "Resumes pure loop state or a live mission."
  @spec resume(LoopState.t() | mission_ref()) ::
          {:ok, LoopState.t()} | runtime_result(SpectreDirective.Pulse.t()) | {:error, term()}
  def resume(%LoopState{} = state), do: Engine.resume(state)
  def resume(ref), do: MissionProcesses.control(ref, :resume)

  @doc "Cancels pure loop state or a live mission."
  @spec cancel(LoopState.t() | mission_ref(), term()) ::
          LoopState.t() | runtime_result(SpectreDirective.Pulse.t())
  def cancel(state_or_ref, reason \\ :cancelled)
  def cancel(%LoopState{} = state, reason), do: Engine.cancel(state, reason)
  def cancel(ref, reason), do: MissionProcesses.control(ref, {:cancel, reason})

  @doc "Creates and starts a mission from a map or keyword list."
  @spec create(map() | keyword()) :: {:ok, pid()} | {:error, term()}
  def create(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    case attr(attrs, [:mission, :goal, :objective]) do
      nil ->
        {:error, :mission_required}

      goal ->
        mission =
          Mission.new(goal,
            context: attr(attrs, :context),
            success: attr(attrs, [:success, :success_criteria]),
            constraints: attr(attrs, :constraints, []),
            risk_boundaries: attr(attrs, :risk_boundaries, []),
            metadata: attr(attrs, :mission_metadata, %{})
          )

        blueprint =
          MissionBlueprint.new(
            name: attr(attrs, :name, mission.goal),
            mission: mission,
            mode: attr(attrs, :mode, :guided),
            source: attr(attrs, :source, :agent_generated),
            plan: attr(attrs, :plan),
            steps: attr(attrs, :steps, []),
            on_complete: attr(attrs, :on_complete),
            metadata: attr(attrs, :metadata, %{})
          )

        start_directive(blueprint, runtime_opts(attrs))
    end
  end

  @doc "Starts an emergent mission from a goal or mission value."
  @spec start_mission(binary() | map() | Mission.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_mission(mission, opts \\ []) do
    mission
    |> MissionBlueprint.from_mission(opts)
    |> start_directive(opts)
  end

  @doc "Starts the optional OTP runtime around existing pure loop state."
  @spec start_loop(LoopState.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_loop(%LoopState{} = loop, opts \\ []) do
    MissionProcesses.start_loop(loop, Keyword.put_new(opts, :execution, :manual))
  end

  @doc "Starts a reusable blueprint or a module authored with `use Spectre.Directive`."
  @spec start_directive(MissionBlueprint.t() | module(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_directive(blueprint_or_module, opts \\ [])

  def start_directive(%MissionBlueprint{} = blueprint, opts) do
    blueprint |> MissionBlueprint.instantiate(opts) |> MissionProcesses.start(opts)
  end

  def start_directive(module, opts) when is_atom(module) do
    name = Keyword.get(opts, :directive)

    case module.__spectre_directive__(name) do
      nil -> {:error, {:directive_not_found, module, name}}
      blueprint -> start_directive(blueprint, opts)
    end
  rescue
    UndefinedFunctionError -> {:error, {:not_a_directive_module, module}}
  end

  @doc "Returns a live mission pulse."
  @spec pulse(mission_ref()) :: runtime_result(SpectreDirective.Pulse.t())
  defdelegate pulse(ref), to: MissionProcesses

  @doc "Returns the complete pure state held by a live mission process."
  @spec state(mission_ref()) :: runtime_result(LoopState.t())
  defdelegate state(ref), to: MissionProcesses

  @doc "Returns the current pending request, if any."
  @spec request(mission_ref()) :: runtime_result(SpectreDirective.Request.t() | nil)
  defdelegate request(ref), to: MissionProcesses

  @doc "Returns the terminal outcome, if any."
  @spec outcome(mission_ref()) :: runtime_result(SpectreDirective.Outcome.t() | nil)
  defdelegate outcome(ref), to: MissionProcesses

  @doc "Returns the causal mission trace."
  @spec trace(mission_ref()) :: runtime_result([SpectreDirective.Trace.Entry.t()])
  defdelegate trace(ref), to: MissionProcesses

  @doc "Returns the living plan."
  @spec plan(mission_ref()) :: runtime_result(SpectreDirective.Plan.t())
  defdelegate plan(ref), to: MissionProcesses

  @doc "Returns a read-only callback context snapshot."
  @spec context(mission_ref()) :: runtime_result(SpectreDirective.Context.t())
  defdelegate context(ref), to: MissionProcesses

  @doc "Subscribes a process to request, information, error, and outcome events."
  @spec subscribe(mission_ref(), pid()) :: :ok | {:error, term()}
  defdelegate subscribe(ref, subscriber \\ self()), to: MissionProcesses

  @doc "Applies a runtime control such as `:pause`, `:resume`, or `{:cancel, reason}`."
  @spec control(mission_ref(), term()) :: runtime_result(SpectreDirective.Pulse.t())
  defdelegate control(ref, action), to: MissionProcesses

  @doc "Stops and removes a live mission process after its state has been handed off."
  @spec stop(mission_ref()) :: :ok | {:error, term()}
  defdelegate stop(ref), to: MissionProcesses

  @doc "Waits for a live mission to reach a terminal outcome."
  @spec await(mission_ref(), timeout()) :: runtime_result(SpectreDirective.Outcome.t())
  defdelegate await(ref, timeout \\ 60_000), to: MissionProcesses

  @spec runtime_opts(map()) :: keyword()
  defp runtime_opts(attrs) do
    [
      :id,
      :reasoner,
      :model,
      :reasoner_opts,
      :execution,
      :request_handler,
      :policy_handler,
      :policy,
      :request_timeout,
      :subscribers,
      :input,
      :assigns,
      :information,
      :max_iterations,
      :runtime_opts
    ]
    |> Enum.reduce([], fn key, opts ->
      case attr(attrs, key) do
        nil -> opts
        value -> Keyword.put(opts, key, value)
      end
    end)
  end

  @spec attr(map(), atom() | [atom()], term()) :: term()
  defp attr(attrs, key_or_keys, default \\ nil)

  defp attr(attrs, keys, default) when is_list(keys) do
    Enum.reduce_while(keys, default, fn key, _default ->
      case fetch_attr(attrs, key) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, default}
      end
    end)
  end

  defp attr(attrs, key, default) when is_atom(key) do
    case fetch_attr(attrs, key) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @spec fetch_attr(map(), atom()) :: {:ok, term()} | :error
  defp fetch_attr(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end

  @spec evaluate_use_options(Macro.t(), Macro.Env.t()) :: keyword()
  defp evaluate_use_options(opts, env) do
    {opts, _binding} = Code.eval_quoted(opts, [], env)

    if Keyword.keyword?(opts) do
      opts
    else
      raise ArgumentError, "use Spectre.Directive expects a keyword list, got: #{inspect(opts)}"
    end
  end
end
