defmodule SpectreDirective do
  @moduledoc """
  Self-correcting mission planner for Spectre agents.

  `use SpectreDirective` is the public mission-authoring surface. Runtime APIs
  start, inspect, control, and complete living missions.

  SpectreDirective is intentionally mission-first. It does not model a fixed
  workflow that blindly runs step 1, step 2, and step 3. It keeps a living plan
  and asks, before and after each step, whether the next action still serves the
  mission.

  ## Authoring

      defmodule MyApp.Directives.Signup do
        use SpectreDirective

        directive "signup-check" do
          mission "Make sure a new user can finish sign up"
          context "This is a release check."
          success "A test user reaches a valid post-signup state."
          mode :guided

          step "Observe signup entry" do
            kind :observe
            purpose "Understand the real signup options before acting"
          end
        end
      end

  ## Running

      {:ok, mission} =
        SpectreDirective.create(%{
          mission: "Make sure a new user can finish sign up",
          context: "This is a release check.",
          success: "A test user reaches a valid post-signup state.",
          capabilities: [:observe_page, :fill_form],
          mode: :guided,
          model: &MyApp.Model.complete/1
        })

  Reusable authored directives can still be started directly:

      {:ok, mission} = SpectreDirective.start_directive(MyApp.Directives.Signup)
      {:ok, step} = SpectreDirective.next_step(mission)

      {:ok, pulse} =
        SpectreDirective.complete_step(mission, %{
          summary: "Signup form is visible.",
          mission_relevant_facts: ["The primary signup path exists."],
          impact: "The release check can continue."
        })

  ## Runtime shape

  A mission moves through:

      Mission -> Knowledge -> Capabilities -> Plan -> Step
      -> Observation -> Impact -> Alignment -> Correction -> Pulse/Trace

  `pulse/1` is the live status snapshot. `trace/1` is the readable story of why
  the mission moved, paused, skipped, corrected, or finished.

  ## AI model connection

  SpectreDirective does not depend on a model SDK. A host application connects a
  model in two places:

    * initial planning through `create(%{model: &MyApp.Model.complete/1})`, or a
      richer `SpectreDirective.Planner` module when the app needs one
    * step execution through an agent loop around the public API

  A planning model receives an English prompt and returns English planning text.
  With `planning_mode: :draft`, the model writes the whole initial plan. With
  `planning_mode: :guided`, SpectreDirective asks for strategy first and then
  one next step at a time. The model does not need to emit JSON or host-language
  maps.

    * call `next_step/1`
    * send the mission pulse, knowledge, and step to the model
    * let the model use host-application tools
    * call `complete_step/2` with an observation map

  Capability adapters advertise what tools or integrations are available.
  The host application's model runner decides which tool to call and translates
  the model result into an observation, impact, and optional correction.
  """

  alias SpectreDirective.MissionBlueprint
  alias SpectreDirective.Pulse
  alias SpectreDirective.Runtime.MissionProcesses

  defmacro __using__(_opts) do
    quote do
      alias SpectreDirective.DSL.Builder

      import Kernel, except: [use: 1, use: 2]
      import SpectreDirective.DSL

      @before_compile SpectreDirective.DSL
      Builder.register(__MODULE__)
    end
  end

  @doc """
  Returns the optional runtime supervisor child spec.

  Host applications may add `SpectreDirective` or
  `SpectreDirective.Runtime.Supervisor` to their supervision tree. Direct calls
  to `start_mission/2` and `start_directive/2` also work without this; the
  runtime infrastructure starts lazily when needed.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts) do
    SpectreDirective.Runtime.Supervisor.child_spec(opts)
  end

  @doc """
  Starts the optional runtime supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) when is_list(opts) do
    SpectreDirective.Runtime.Supervisor.start_link(opts)
  end

  @doc """
  Creates and starts a mission from one simple map or keyword list.

  This is the ergonomic API for agent-created missions. It accepts the mission
  description, optional inline capabilities, and a model function that receives
  SpectreDirective's English planning prompts.

      {:ok, mission} =
        SpectreDirective.create(%{
          mission: "Make sure a new user can finish sign up",
          context: "This is a release check. Do not use real customer data.",
          success: "A test user reaches a valid post-signup state.",
          capabilities: [:observe_page, :fill_form],
          mode: :guided,
          model: &MyApp.Model.complete/1
        })

  `mode: :guided` selects guided planning. Use `planning_mode: :draft` or
  `directive_mode: :adaptive` when those meanings should differ.
  """
  @spec create(map() | keyword()) :: {:ok, pid()} | {:error, term()}
  def create(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    with {:ok, mission} <- create_mission(attrs) do
      start_mission(mission, create_opts(attrs))
    end
  end

  @doc """
  Starts an emergent mission from a goal or mission map.
  """
  @spec start_mission(binary() | map() | SpectreDirective.Mission.t(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_mission(mission, opts \\ []) do
    mission
    |> MissionBlueprint.from_mission(opts)
    |> start_directive(opts)
  end

  @doc """
  Starts an authored, emergent, or hybrid directive.
  """
  @spec start_directive(MissionBlueprint.t() | module(), keyword()) ::
          {:ok, pid()} | {:error, term()}
  def start_directive(blueprint_or_module, opts \\ [])

  def start_directive(%MissionBlueprint{} = blueprint, opts),
    do: MissionProcesses.start(fresh_blueprint(blueprint, opts), opts)

  def start_directive(module, opts) when is_atom(module) do
    name = Keyword.get(opts, :directive)

    case module.__spectre_directive__(name) do
      nil -> {:error, {:directive_not_found, module, name}}
      blueprint -> start_directive(blueprint, opts)
    end
  rescue
    UndefinedFunctionError -> {:error, {:not_a_directive_module, module}}
  end

  @doc "Returns the live pulse for a mission."
  @spec pulse(pid() | binary()) :: {:ok, Pulse.t()} | {:error, term()}
  defdelegate pulse(ref), to: MissionProcesses

  @doc "Returns the meaningful mission trace."
  @spec trace(pid() | binary()) :: {:ok, [SpectreDirective.Trace.Entry.t()]} | {:error, term()}
  defdelegate trace(ref), to: MissionProcesses

  @doc "Returns the current living plan."
  @spec plan(pid() | binary()) :: {:ok, SpectreDirective.Plan.t()} | {:error, term()}
  defdelegate plan(ref), to: MissionProcesses

  @doc "Returns the current mission knowledge."
  @spec knowledge(pid() | binary()) :: {:ok, SpectreDirective.Knowledge.t()} | {:error, term()}
  defdelegate knowledge(ref), to: MissionProcesses

  @doc "Returns the current step, selecting one if needed."
  @spec next_step(pid() | binary()) :: {:ok, SpectreDirective.Step.t() | nil} | {:error, term()}
  defdelegate next_step(ref), to: MissionProcesses

  @doc """
  Completes a step with an observation payload.
  """
  @spec complete_step(pid() | binary(), term()) :: {:ok, Pulse.t()} | {:error, term()}
  defdelegate complete_step(ref, observation), to: MissionProcesses

  @doc """
  Applies an observation to the current step.
  """
  @spec apply_observation(pid() | binary(), term()) :: {:ok, Pulse.t()} | {:error, term()}
  defdelegate apply_observation(ref, observation), to: MissionProcesses

  @doc """
  Sends a control action to a mission.
  """
  @spec control(pid() | binary(), term()) :: {:ok, Pulse.t()} | {:error, term()}
  defdelegate control(ref, action), to: MissionProcesses

  @doc """
  Waits until a mission reaches a terminal state.
  """
  @spec await(pid() | binary(), timeout()) :: {:ok, Pulse.t()} | {:error, term()}
  def await(ref, timeout \\ 60_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(ref, deadline)
  end

  @spec do_await(pid() | binary(), integer()) :: {:ok, Pulse.t()} | {:error, term()}
  defp do_await(ref, deadline) do
    case pulse(ref) do
      {:ok, %Pulse{status: status} = pulse} when status in [:finished, :stopped, :aborted] ->
        {:ok, pulse}

      {:ok, _pulse} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(20)
          do_await(ref, deadline)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec fresh_blueprint(MissionBlueprint.t(), keyword()) :: MissionBlueprint.t()
  defp fresh_blueprint(%MissionBlueprint{} = blueprint, opts) do
    mission_id = Keyword.get(opts, :id) || SpectreDirective.ID.new("mission")

    %{
      blueprint
      | id: SpectreDirective.ID.new("blueprint"),
        mission: %{blueprint.mission | id: mission_id, status: :draft}
    }
  end

  @spec create_mission(map()) :: {:ok, map()} | {:error, :mission_required}
  defp create_mission(attrs) do
    case attr(attrs, [:mission, :goal]) do
      nil ->
        {:error, :mission_required}

      mission ->
        {:ok,
         %{
           goal: mission,
           context: attr(attrs, :context),
           success: attr(attrs, [:success, :success_criteria]),
           constraints: List.wrap(attr(attrs, :constraints, [])),
           risk_boundaries: List.wrap(attr(attrs, :risk_boundaries, [])),
           memory_scope: attr(attrs, :memory_scope),
           metadata: Map.new(attr(attrs, :metadata, %{}))
         }}
    end
  end

  @spec create_opts(map()) :: keyword()
  defp create_opts(attrs) do
    [
      mode: directive_mode(attrs),
      planning_mode: planning_mode(attrs),
      planning_model: planning_model(attrs),
      planning_max_steps: attr(attrs, :planning_max_steps),
      capabilities: attr(attrs, :capabilities, []),
      capability_adapters: attr(attrs, :capability_adapters, []),
      memory_adapter: attr(attrs, :memory_adapter),
      memory_opts: attr(attrs, :memory_opts, []),
      planner: attr(attrs, :planner),
      strategies: attr(attrs, :strategies),
      steps: attr(attrs, :steps),
      name: attr(attrs, :name),
      id: attr(attrs, :id)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  @spec directive_mode(map()) :: MissionBlueprint.mode()
  defp directive_mode(attrs) do
    case attr(attrs, [:directive_mode, :mode]) do
      mode when mode in [:strict, :guided, :adaptive] -> mode
      _mode -> :adaptive
    end
  end

  @spec planning_mode(map()) :: :draft | :guided
  defp planning_mode(attrs) do
    case attr(attrs, [:planning_mode, :planning, :mode]) do
      :guided -> :guided
      _mode -> :draft
    end
  end

  @spec planning_model(map()) :: function() | nil
  defp planning_model(attrs) do
    attr(attrs, [:planning_model, :model, :llm, :complete])
  end

  @spec attr(map(), atom() | [atom()], term()) :: term()
  defp attr(attrs, key_or_keys, default \\ nil)

  defp attr(attrs, keys, default) when is_list(keys) do
    Enum.find_value(keys, default, &attr(attrs, &1))
  end

  defp attr(attrs, key, default) when is_atom(key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key)) || default
  end
end
