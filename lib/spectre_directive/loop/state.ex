defmodule SpectreDirective.Loop.State do
  @moduledoc "Live, state-passing representation of one mission loop."

  alias SpectreDirective.Context
  alias SpectreDirective.Mission
  alias SpectreDirective.Outcome
  alias SpectreDirective.Plan
  alias SpectreDirective.Request
  alias SpectreDirective.Trace.Entry
  alias SpectreDirective.WorkingContext

  @type mode :: :fixed | :guided | :autonomous
  @type status :: :running | :waiting | :paused | :blocked | :completed | :failed | :cancelled

  @type t :: %__MODULE__{
          mission: Mission.executable_t(),
          plan: Plan.t(),
          working_context: WorkingContext.t(),
          mode: mode(),
          status: status(),
          reasoner: term(),
          reasoner_opts: keyword(),
          on_complete: term(),
          pending_request: Request.t() | nil,
          pending_proposal: term(),
          outcome: Outcome.t() | nil,
          plan_confirmed?: boolean(),
          step_invoked?: boolean(),
          completion_started?: boolean(),
          pending_completion_result: term(),
          iteration: non_neg_integer(),
          max_iterations: pos_integer(),
          trace: [Entry.t()],
          metadata: map()
        }

  defstruct [
    :mission,
    :plan,
    :reasoner,
    :on_complete,
    :pending_request,
    :pending_proposal,
    :outcome,
    :pending_completion_result,
    mode: :guided,
    status: :running,
    working_context: %WorkingContext{},
    reasoner_opts: [],
    plan_confirmed?: false,
    step_invoked?: false,
    completion_started?: false,
    iteration: 0,
    max_iterations: 100,
    trace: [],
    metadata: %{}
  ]

  @doc "Builds pure loop state from normalized options."
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Map.new(attrs)

    with {:ok, mission} <- mission(attrs),
         {:ok, plan} <- plan(attrs) do
      working_context =
        WorkingContext.new(
          input: Map.get(attrs, :input),
          assigns: Map.get(attrs, :assigns, %{}),
          information: Map.get(attrs, :information, [])
        )

      state = %__MODULE__{
        mission: %{mission | status: :running},
        plan: plan,
        working_context: working_context,
        mode: normalize_mode(Map.get(attrs, :mode, :guided)),
        reasoner: Map.get(attrs, :reasoner) || Map.get(attrs, :model),
        reasoner_opts: List.wrap(Map.get(attrs, :reasoner_opts, [])),
        on_complete: Map.get(attrs, :on_complete),
        plan_confirmed?: boolean_value(Map.get(attrs, :plan_confirmed?), plan.steps != []),
        max_iterations: positive_integer(Map.get(attrs, :max_iterations, 100), 100),
        metadata: Map.new(Map.get(attrs, :metadata, %{}))
      }

      {:ok, add_trace(state, :started, "Started mission: #{mission.goal}")}
    end
  rescue
    error -> {:error, {:invalid_loop_state, error}}
  end

  def new(attrs), do: {:error, {:invalid_loop_options, attrs}}

  @doc "Returns a callback-safe snapshot."
  @spec context(t(), atom() | nil) :: Context.t()
  def context(%__MODULE__{} = state, operation \\ nil) do
    %Context{
      mission: state.mission,
      plan: state.plan,
      mode: state.mode,
      plan_status: state.status,
      step: Plan.current_step(state.plan),
      information: state.working_context.information,
      last_result: state.working_context.last_result,
      input: state.working_context.input,
      assigns: state.working_context.assigns,
      revision: state.working_context.revision,
      iteration: state.iteration,
      operation: operation
    }
  end

  @doc "Changes loop and mission status together."
  @spec put_status(t(), status()) :: t()
  def put_status(%__MODULE__{} = state, status) do
    %{state | status: status, mission: %{state.mission | status: status}}
  end

  @doc "Appends a causal trace entry."
  @spec add_trace(t(), atom(), binary(), term()) :: t()
  def add_trace(%__MODULE__{} = state, type, message, data \\ nil) do
    entry = Entry.new(state.mission.id, type, message, data)
    %{state | trace: state.trace ++ [entry]}
  end

  @spec mission(map()) :: {:ok, Mission.executable_t()} | {:error, term()}
  defp mission(attrs) do
    case Map.get(attrs, :mission) || Map.get(attrs, :goal) do
      nil ->
        {:error, :mission_required}

      mission ->
        mission = Mission.new(mission, mission_opts(attrs))

        if is_binary(mission.goal) and String.trim(mission.goal) != "" do
          {:ok, mission}
        else
          {:error, :mission_goal_required}
        end
    end
  end

  @spec mission_opts(map()) :: keyword()
  defp mission_opts(attrs) do
    [
      context: Map.get(attrs, :context),
      success: Map.get(attrs, :success) || Map.get(attrs, :success_criteria),
      constraints: Map.get(attrs, :constraints, []),
      risk_boundaries: Map.get(attrs, :risk_boundaries, []),
      metadata: Map.get(attrs, :mission_metadata, %{})
    ]
  end

  @spec plan(map()) :: {:ok, Plan.t()} | {:error, term()}
  defp plan(attrs) do
    case Map.fetch(attrs, :plan) do
      {:ok, %Plan{} = plan} -> {:ok, plan}
      {:ok, plan} -> {:ok, Plan.new(plan || [])}
      :error -> plan_from_steps(attrs)
    end
  rescue
    error -> {:error, {:invalid_plan, error}}
  end

  @spec plan_from_steps(map()) :: {:ok, Plan.t()}
  defp plan_from_steps(attrs) do
    case Map.fetch(attrs, :steps) do
      {:ok, steps} -> authored_or_generated_plan(List.wrap(steps))
      :error -> generated_plan()
    end
  end

  @spec authored_or_generated_plan(list()) :: {:ok, Plan.t()}
  defp authored_or_generated_plan([]), do: generated_plan()
  defp authored_or_generated_plan(steps), do: {:ok, Plan.new(steps, source: :authored)}

  @spec generated_plan() :: {:ok, Plan.t()}
  defp generated_plan, do: {:ok, Plan.new([], source: :agent_generated)}

  @spec normalize_mode(term()) :: mode()
  defp normalize_mode(:strict), do: :fixed
  defp normalize_mode(:adaptive), do: :autonomous
  defp normalize_mode(mode) when mode in [:fixed, :guided, :autonomous], do: mode
  defp normalize_mode(_mode), do: :guided

  @spec positive_integer(term(), pos_integer()) :: pos_integer()
  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default

  @spec boolean_value(term(), boolean()) :: boolean()
  defp boolean_value(value, _default) when is_boolean(value), do: value
  defp boolean_value(_value, default), do: default
end
