defmodule Spectre.Directive do
  @moduledoc """
  Public API for authored and emergent self-correcting mission loops.

  Directive can be used as a pure reducer, as a supervised OTP runtime, inside
  a regular GenServer, or together with `Spectre.Agent`. The package defines
  this namespace and publishes an immutable Spectre Stack installation that
  activates continuity on Stack-bound Agents without claiming ownership of its
  optional runtime. The standalone mission engine remains an explicitly
  selected host facility; it is never used as a second `Spectre.Run`
  executor.

  Use the DSL in an application module:

      defmodule MyApp.ClientResearch do
        use Spectre.Directive

        directive "client-research" do
          mission "Research the client"
          mode :guided
        end
      end

  See the project README for complete standalone, Agent, and GenServer flows.
  """

  alias Spectre.Directive.StackCompiler
  alias SpectreDirective.Context
  alias SpectreDirective.Loop.Engine
  alias SpectreDirective.Loop.State
  alias SpectreDirective.Mission
  alias SpectreDirective.MissionBlueprint
  alias SpectreDirective.Outcome
  alias SpectreDirective.Plan
  alias SpectreDirective.Pulse
  alias SpectreDirective.Request
  alias SpectreDirective.Trace.Entry

  use Spectre.Stack.Installable,
    id: :directive,
    version: "0.1.3",
    contract: 1,
    spectre: "~> 0.1.3",
    provides: [{:service, :continuity}],
    requires: [],
    conflicts: [],
    operations: [],
    actions: [],
    resources: [],
    agent_extensions: [Spectre.Directive.Extension],
    dsl: __MODULE__,
    metadata: %{application: :spectre_directive, role: :continuity}

  @type mission_ref :: pid() | binary()
  @type runtime_result(value) :: {:ok, value} | {:error, term()}
  @type input_boundary :: {:request, Request.t()} | {:outcome, Outcome.t()}

  @impl Spectre.Stack.Installable
  def compile(opts, block, caller) do
    StackCompiler.compile(opts, block, caller)
  end

  @doc "Imports the Directive DSL and installs the appropriate host integration."
  @spec __using__(keyword()) :: Macro.t()
  defmacro __using__(opts) do
    quote do
      use SpectreDirective, unquote(opts)
    end
  end

  @doc """
  Returns the immutable Directive installation bound to an Agent.

  Stack-bound Agents receive this configuration automatically from the
  Directive extension. The continuity turn handler is installed only when the
  package is mounted with `turn_handler: true`; the default installation
  contributes data and no competing turn executor.
  """
  @spec config(module()) :: {:ok, map()} | {:error, term()}
  def config(agent) when is_atom(agent) do
    with {:ok, mount} <- Spectre.Extension.fetch(agent, :directive),
         config when is_map(config) <- mount.compiled do
      {:ok, config}
    else
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_directive_configuration}
    end
  end

  @doc "Returns a child specification for the optional Directive runtime supervisor."
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  defdelegate child_spec(opts), to: SpectreDirective

  @doc "Starts the optional Directive runtime supervision tree."
  @spec start_link(keyword()) :: Supervisor.on_start()
  defdelegate start_link(opts \\ []), to: SpectreDirective

  @doc "Creates pure mission-loop state without starting a process or callback."
  @spec new(map() | keyword()) :: {:ok, State.t()} | {:error, term()}
  defdelegate new(attrs), to: SpectreDirective

  @doc "Projects callback context into model-safe data without executable targets."
  @spec context_map(Context.t()) :: map()
  defdelegate context_map(context), to: SpectreDirective

  @doc "Builds the provider-neutral protocol and context payload for an LLM."
  @spec reasoning_input(Context.t()) :: map()
  defdelegate reasoning_input(context), to: SpectreDirective

  @doc "Returns the provider-neutral reasoner decision protocol."
  @spec protocol() :: map()
  defdelegate protocol(), to: SpectreDirective

  @doc "Advances a pure loop to its next external request or terminal outcome."
  @spec next(State.t()) :: Engine.next_result()
  defdelegate next(state), to: SpectreDirective

  @doc "Applies a response correlated to a pure or live mission request."
  @spec respond(State.t() | mission_ref(), binary(), term()) ::
          Engine.result() | runtime_result(Pulse.t())
  defdelegate respond(state_or_ref, request_id, response), to: SpectreDirective

  @doc "Responds to the currently pending request of a live mission."
  @spec respond(mission_ref(), term()) :: runtime_result(Pulse.t())
  defdelegate respond(ref, response), to: SpectreDirective

  @doc "Adds mission-local information and invalidates stale reasoning when necessary."
  @spec inform(State.t() | mission_ref(), term(), keyword()) ::
          {:ok, State.t()} | runtime_result(Pulse.t()) | {:error, term()}
  defdelegate inform(state_or_ref, information, opts \\ []), to: SpectreDirective

  @doc "Merges application-owned assigns into future callback contexts."
  @spec assign(State.t() | mission_ref(), map()) ::
          {:ok, State.t()} | runtime_result(Pulse.t()) | {:error, term()}
  defdelegate assign(state_or_ref, assigns), to: SpectreDirective

  @doc "Pauses a pure loop or live mission."
  @spec pause(State.t() | mission_ref()) ::
          {:ok, State.t()} | runtime_result(Pulse.t()) | {:error, term()}
  defdelegate pause(state), to: SpectreDirective

  @doc "Resumes a paused or blocked pure loop or live mission."
  @spec resume(State.t() | mission_ref()) ::
          {:ok, State.t()} | runtime_result(Pulse.t()) | {:error, term()}
  defdelegate resume(state), to: SpectreDirective

  @doc "Cancels a pure loop or live mission with an optional reason."
  @spec cancel(State.t() | mission_ref(), term()) :: State.t() | runtime_result(Pulse.t())
  defdelegate cancel(state, reason \\ :cancelled), to: SpectreDirective

  @doc "Creates and starts a live mission from a map or keyword payload."
  @spec create(map() | keyword()) :: {:ok, pid()} | {:error, term()}
  defdelegate create(attrs), to: SpectreDirective

  @doc "Starts an emergent live mission from a goal or mission value."
  @spec start_mission(binary() | map() | Mission.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  defdelegate start_mission(mission, opts \\ []), to: SpectreDirective

  @doc "Starts a manually driven OTP runtime around existing pure loop state."
  @spec start_loop(State.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  defdelegate start_loop(loop, opts \\ []), to: SpectreDirective

  @doc "Starts an authored mission blueprint or a module using the Directive DSL."
  @spec start_directive(MissionBlueprint.t() | module(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  defdelegate start_directive(blueprint_or_module, opts \\ []), to: SpectreDirective

  @doc "Returns a compact view of a live mission."
  @spec pulse(mission_ref()) :: runtime_result(Pulse.t())
  defdelegate pulse(ref), to: SpectreDirective

  @doc "Returns the complete pure state held by a live mission process."
  @spec state(mission_ref()) :: runtime_result(State.t())
  defdelegate state(ref), to: SpectreDirective

  @doc "Returns the currently pending request, if one exists."
  @spec request(mission_ref()) :: runtime_result(Request.t() | nil)
  defdelegate request(ref), to: SpectreDirective

  @doc "Returns the terminal mission outcome, if the mission has finished."
  @spec outcome(mission_ref()) :: runtime_result(Outcome.t() | nil)
  defdelegate outcome(ref), to: SpectreDirective

  @doc "Returns the ordered causal trace of a live mission."
  @spec trace(mission_ref()) :: runtime_result([Entry.t()])
  defdelegate trace(ref), to: SpectreDirective

  @doc "Returns the current versioned plan of a live mission."
  @spec plan(mission_ref()) :: runtime_result(Plan.t())
  defdelegate plan(ref), to: SpectreDirective

  @doc "Returns a read-only callback context snapshot for a live mission."
  @spec context(mission_ref()) :: runtime_result(Context.t())
  defdelegate context(ref), to: SpectreDirective

  @doc "Subscribes a process to requests, information, traces, errors, and outcomes."
  @spec subscribe(mission_ref(), pid()) :: :ok | {:error, term()}
  defdelegate subscribe(ref, subscriber \\ self()), to: SpectreDirective

  @doc "Applies a runtime control such as pause, resume, or cancellation."
  @spec control(mission_ref(), term()) :: runtime_result(Pulse.t())
  defdelegate control(ref, action), to: SpectreDirective

  @doc "Stops and removes a live mission process."
  @spec stop(mission_ref()) :: :ok | {:error, term()}
  defdelegate stop(ref), to: SpectreDirective

  @doc "Waits until a live mission reaches a terminal outcome or the timeout expires."
  @spec await(mission_ref(), timeout()) :: runtime_result(Outcome.t())
  defdelegate await(ref, timeout \\ 60_000), to: SpectreDirective

  @doc """
  Waits for the next user-owned request or the terminal mission outcome.

  The runtime skips its internal reason/invoke work and returns
  `{:request, request}` for questions, confirmations, and policy decisions, or
  `{:outcome, outcome}` when the mission finishes. This helper is intended for
  automatic runtimes; a manual reason/invoke boundary remains host-owned.
  """
  @spec await_input(mission_ref(), timeout()) :: runtime_result(input_boundary())
  defdelegate await_input(ref, timeout \\ 60_000), to: SpectreDirective

  @doc """
  Replies to the current user-owned request and waits for the next boundary.

  Use this for synchronous CLI and test flows. Event-driven applications can
  subscribe to the mission and respond by request id with `respond/3` instead.
  """
  @spec reply(mission_ref(), term(), timeout()) :: runtime_result(input_boundary())
  defdelegate reply(ref, response, timeout \\ 60_000), to: SpectreDirective
end
