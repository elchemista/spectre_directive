defmodule SpectreDirective.Plan do
  @moduledoc """
  The current strategy for a mission. It is expected to change.

  A plan is versioned because correction is normal, not exceptional. Each
  revision records a reason and optional correction payload so a monitor can ask
  why a mission changed direction.

      Plan v1: inspect every repository
      Plan v2: inspect only frontend candidates

  In the runtime, completed and skipped steps remain visible. They are part of
  the mission story and help prevent redundant or low-value work.
  """

  alias SpectreDirective.ID
  alias SpectreDirective.Step

  @type source :: :authored | :agent_generated | :hybrid

  @type revision :: %{
          required(:version) => pos_integer(),
          required(:reason) => binary(),
          required(:timestamp) => DateTime.t(),
          optional(:correction) => term()
        }

  @type t :: %__MODULE__{
          id: binary(),
          version: pos_integer(),
          reason: binary() | nil,
          source: source(),
          steps: [Step.t()],
          skipped_steps: [Step.t()],
          completed_steps: [Step.t()],
          revision_history: [revision()],
          current_step_id: binary() | nil
        }

  defstruct [
    :id,
    :reason,
    :current_step_id,
    version: 1,
    source: :authored,
    steps: [],
    skipped_steps: [],
    completed_steps: [],
    revision_history: []
  ]

  @doc """
  Builds a plan from steps or a plan attribute payload.
  """
  @spec new([Step.t() | map()] | map() | keyword(), keyword()) :: t()
  def new(plan, opts \\ [])

  def new(steps, opts) when is_list(steps) do
    if Keyword.keyword?(steps) and Keyword.has_key?(steps, :steps) do
      new(Map.new(steps), opts)
    else
      %__MODULE__{
        id: Keyword.get(opts, :id) || ID.new("plan"),
        reason: Keyword.get(opts, :reason),
        source: Keyword.get(opts, :source, :authored),
        steps: Enum.map(steps, &normalize_step/1)
      }
    end
  end

  def new(attrs, opts) when is_map(attrs) do
    %__MODULE__{
      id: Map.get(attrs, :id) || Keyword.get(opts, :id) || ID.new("plan"),
      version: Map.get(attrs, :version, 1),
      reason: Map.get(attrs, :reason),
      source: Map.get(attrs, :source, :authored),
      steps: Enum.map(Map.get(attrs, :steps, []), &normalize_step/1),
      skipped_steps: Enum.map(Map.get(attrs, :skipped_steps, []), &normalize_step/1),
      completed_steps: Enum.map(Map.get(attrs, :completed_steps, []), &normalize_step/1),
      revision_history: Map.get(attrs, :revision_history, []),
      current_step_id: Map.get(attrs, :current_step_id)
    }
  end

  @doc """
  Returns pending steps in plan order.
  """
  @spec pending_steps(t()) :: [Step.t()]
  def pending_steps(%__MODULE__{} = plan), do: Enum.filter(plan.steps, &(&1.status == :pending))

  @doc """
  Returns the current running step, if one is selected.
  """
  @spec current_step(t()) :: Step.t() | nil
  def current_step(%__MODULE__{current_step_id: nil}), do: nil

  def current_step(%__MODULE__{} = plan) do
    Enum.find(plan.steps, &(&1.id == plan.current_step_id))
  end

  @doc """
  Returns the next pending step in plan order.
  """
  @spec next_pending(t()) :: Step.t() | nil
  def next_pending(%__MODULE__{} = plan), do: Enum.find(plan.steps, &(&1.status == :pending))

  @doc """
  Marks a step as the current running step.
  """
  @spec put_current(t(), Step.t() | nil) :: t()
  def put_current(plan, nil), do: %{plan | current_step_id: nil}

  def put_current(%__MODULE__{} = plan, %Step{} = step) do
    update_step(%{plan | current_step_id: step.id}, %{step | status: :running})
  end

  @doc """
  Replaces a step and refreshes completed/skipped indexes.
  """
  @spec update_step(t(), Step.t()) :: t()
  def update_step(%__MODULE__{} = plan, %Step{} = step) do
    steps =
      Enum.map(plan.steps, fn existing -> if existing.id == step.id, do: step, else: existing end)

    %{
      plan
      | steps: steps,
        completed_steps: Enum.filter(steps, &(&1.status == :completed)),
        skipped_steps: Enum.filter(steps, &(&1.status == :skipped))
    }
  end

  @doc """
  Adds a correction-created step and records a plan revision.
  """
  @spec add_step(t(), Step.t() | map(), binary()) :: t()
  def add_step(%__MODULE__{} = plan, step, reason) do
    step = step |> normalize_step() |> Map.put(:source, :correction_added)

    revise(%{plan | steps: plan.steps ++ [step]}, reason, %{type: :add_step, step_id: step.id})
  end

  @doc """
  Removes matching steps and records a plan revision.
  """
  @spec remove_matching(t(), (Step.t() -> boolean()), binary()) :: t()
  def remove_matching(%__MODULE__{} = plan, predicate, reason) when is_function(predicate, 1) do
    removed = Enum.filter(plan.steps, predicate)
    kept = Enum.reject(plan.steps, predicate)

    revise(%{plan | steps: kept}, reason, %{
      type: :remove_steps,
      removed: Enum.map(removed, & &1.id)
    })
  end

  @doc """
  Records a plan revision without changing the step list.
  """
  @spec revise(t(), binary(), term()) :: t()
  def revise(%__MODULE__{} = plan, reason, correction \\ nil) do
    revision = %{
      version: plan.version + 1,
      reason: reason,
      correction: correction,
      timestamp: DateTime.utc_now()
    }

    %{plan | version: plan.version + 1, revision_history: plan.revision_history ++ [revision]}
  end

  @spec normalize_step(Step.t() | map() | keyword()) :: Step.t()
  defp normalize_step(%Step{} = step), do: step
  defp normalize_step(attrs), do: Step.new(attrs)
end
