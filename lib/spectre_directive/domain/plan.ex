defmodule SpectreDirective.Plan do
  @moduledoc """
  The versioned, living strategy for a mission.

  Completed and skipped steps remain visible so the host and reasoner can
  understand what happened and avoid repeating work.
  """

  alias SpectreDirective.ID
  alias SpectreDirective.Step

  @type source :: :authored | :agent_generated | :hybrid
  @step_statuses [:pending, :running, :completed, :skipped, :blocked, :failed]
  @sources [:authored, :agent_generated, :hybrid]

  @type revision :: %{
          required(:version) => pos_integer(),
          required(:reason) => binary(),
          required(:timestamp) => DateTime.t(),
          optional(:change) => term()
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
      |> refresh_indexes()
      |> validate!()
    end
  end

  def new(attrs, opts) when is_map(attrs) do
    steps = normalize_plan_steps(attrs)

    %__MODULE__{
      id: value(attrs, :id) || Keyword.get(opts, :id) || ID.new("plan"),
      version: value(attrs, :version, 1),
      reason: value(attrs, :reason),
      source: value(attrs, :source, :authored),
      steps: steps,
      revision_history: value(attrs, :revision_history, []),
      current_step_id: value(attrs, :current_step_id)
    }
    |> refresh_indexes()
    |> validate!()
  end

  @doc false
  @spec validate(term()) :: :ok | {:error, term()}
  def validate(%__MODULE__{id: id, steps: steps, current_step_id: current_step_id} = plan)
      when is_list(steps) do
    with :ok <- validate_id(id, :plan),
         :ok <- validate_version(plan.version),
         :ok <- validate_source(plan.source),
         :ok <- validate_revision_history(plan.revision_history),
         {:ok, step_ids} <- validate_step_ids(steps),
         :ok <- validate_current_step_id(current_step_id, step_ids) do
      validate_indexes(plan)
    end
  end

  def validate(%__MODULE__{steps: steps}), do: {:error, {:invalid_plan_steps, steps}}
  def validate(plan), do: {:error, {:invalid_plan, plan}}

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
  def put_current(%__MODULE__{} = plan, nil) do
    plan
    |> Map.put(:current_step_id, nil)
    |> validate!()
  end

  def put_current(%__MODULE__{} = plan, %Step{} = step) do
    case Enum.find(plan.steps, &(&1.id == step.id)) do
      nil ->
        raise ArgumentError,
              "step #{inspect(step.id)} does not belong to plan #{inspect(plan.id)}"

      existing ->
        update_step(%{plan | current_step_id: existing.id}, %{existing | status: :running})
    end
  end

  @doc """
  Replaces a step and refreshes completed/skipped indexes.
  """
  @spec update_step(t(), Step.t()) :: t()
  def update_step(%__MODULE__{} = plan, %Step{} = step) do
    plan = validate!(plan)

    if Enum.any?(plan.steps, &(&1.id == step.id)) do
      step_id = step.id

      steps =
        Enum.map(plan.steps, fn
          %Step{id: ^step_id} -> step
          existing -> existing
        end)

      plan
      |> Map.put(:steps, steps)
      |> refresh_indexes()
      |> validate!()
    else
      raise ArgumentError, "step #{inspect(step.id)} does not belong to plan #{inspect(plan.id)}"
    end
  end

  @doc """
  Adds a generated step and records a plan revision.
  """
  @spec add_step(t(), Step.t() | map(), binary()) :: t()
  def add_step(%__MODULE__{} = plan, step, reason) do
    step = normalize_generated_step(step)

    plan
    |> Map.update!(:steps, &(&1 ++ [step]))
    |> validate!()
    |> revise(reason, %{type: :add_step, step_id: step.id})
  end

  @doc """
  Removes matching steps and records a plan revision.
  """
  @spec remove_matching(t(), (Step.t() -> boolean()), binary()) :: t()
  def remove_matching(%__MODULE__{} = plan, predicate, reason) when is_function(predicate, 1) do
    {removed, kept} = Enum.split_with(plan.steps, predicate)
    removed_ids = MapSet.new(removed, & &1.id)

    current_step_id =
      if MapSet.member?(removed_ids, plan.current_step_id), do: nil, else: plan.current_step_id

    plan
    |> Map.merge(%{steps: kept, current_step_id: current_step_id})
    |> refresh_indexes()
    |> validate!()
    |> revise(reason, %{
      type: :remove_steps,
      removed: Enum.map(removed, & &1.id)
    })
  end

  @doc """
  Records a plan revision without changing the step list.
  """
  @spec revise(t(), binary(), term()) :: t()
  def revise(%__MODULE__{} = plan, reason, change \\ nil) do
    plan = validate!(plan)

    revision = %{
      version: plan.version + 1,
      reason: reason,
      change: change,
      timestamp: DateTime.utc_now()
    }

    %{plan | version: plan.version + 1, revision_history: plan.revision_history ++ [revision]}
  end

  @spec normalize_step(Step.t() | map() | keyword()) :: Step.t()
  defp normalize_step(step), do: Step.new(step)

  @spec normalize_plan_steps(map()) :: [Step.t()]
  defp normalize_plan_steps(attrs) do
    steps = Enum.map(value(attrs, :steps, []), &normalize_step/1)

    indexed_steps =
      Enum.map(value(attrs, :skipped_steps, []), &Step.new(&1, status: :skipped)) ++
        Enum.map(value(attrs, :completed_steps, []), &Step.new(&1, status: :completed))

    status_by_id = indexed_statuses(indexed_steps)
    main_ids = MapSet.new(steps, & &1.id)

    normalized =
      Enum.map(steps, fn step ->
        case Map.fetch(status_by_id, step.id) do
          {:ok, status} -> %{step | status: status}
          :error -> step
        end
      end)

    appended =
      indexed_steps
      |> Enum.reject(&MapSet.member?(main_ids, &1.id))
      |> Enum.uniq_by(& &1.id)

    normalized ++ appended
  end

  @spec indexed_statuses([Step.t()]) :: %{optional(term()) => Step.status()}
  defp indexed_statuses(indexed_steps) do
    Enum.reduce(indexed_steps, %{}, fn step, statuses ->
      case Map.fetch(statuses, step.id) do
        {:ok, status} when status != step.status ->
          raise ArgumentError,
                "step #{inspect(step.id)} appears in conflicting skipped/completed indexes"

        _existing_or_missing ->
          Map.put(statuses, step.id, step.status)
      end
    end)
  end

  @spec normalize_generated_step(Step.t() | map() | keyword()) :: Step.t()
  defp normalize_generated_step(step) do
    Step.new(step,
      status: :pending,
      attempts: 0,
      evidence: [],
      result: nil,
      source: :generated
    )
  end

  @spec refresh_indexes(t()) :: t()
  defp refresh_indexes(%__MODULE__{} = plan) do
    %{
      plan
      | completed_steps: Enum.filter(plan.steps, &(&1.status == :completed)),
        skipped_steps: Enum.filter(plan.steps, &(&1.status == :skipped))
    }
  end

  @spec validate_indexes(t()) :: :ok | {:error, term()}
  defp validate_indexes(%__MODULE__{} = plan) do
    expected_completed = Enum.filter(plan.steps, &(&1.status == :completed))
    expected_skipped = Enum.filter(plan.steps, &(&1.status == :skipped))

    cond do
      plan.completed_steps != expected_completed -> {:error, {:stale_plan_index, :completed}}
      plan.skipped_steps != expected_skipped -> {:error, {:stale_plan_index, :skipped}}
      true -> :ok
    end
  end

  @spec validate!(t()) :: t()
  defp validate!(%__MODULE__{} = plan) do
    case validate(plan) do
      :ok -> plan
      {:error, reason} -> raise ArgumentError, "invalid plan: #{inspect(reason)}"
    end
  end

  @spec validate_step_ids([term()]) :: {:ok, MapSet.t(binary())} | {:error, term()}
  defp validate_step_ids(steps) do
    Enum.reduce_while(steps, {:ok, MapSet.new()}, fn
      %Step{id: id} = step, {:ok, ids} ->
        cond do
          not valid_id?(id) ->
            {:halt, {:error, {:invalid_plan_step_id, id}}}

          not valid_step_status?(step) ->
            {:halt, {:error, {:invalid_plan_step_status, id, step.status}}}

          not valid_step_attempts?(step) ->
            {:halt, {:error, {:invalid_plan_step_attempts, id, step.attempts}}}

          MapSet.member?(ids, id) ->
            {:halt, {:error, {:duplicate_plan_step, id}}}

          true ->
            {:cont, {:ok, MapSet.put(ids, id)}}
        end

      step, _ids ->
        {:halt, {:error, {:invalid_plan_step, step}}}
    end)
  end

  @spec validate_current_step_id(term(), MapSet.t(binary())) :: :ok | {:error, term()}
  defp validate_current_step_id(nil, _step_ids), do: :ok

  defp validate_current_step_id(current_step_id, step_ids) do
    if MapSet.member?(step_ids, current_step_id),
      do: :ok,
      else: {:error, {:unknown_current_plan_step, current_step_id}}
  end

  @spec validate_id(term(), atom()) :: :ok | {:error, term()}
  defp validate_id(id, _kind) when is_binary(id) do
    if String.trim(id) == "", do: {:error, {:invalid_plan_id, id}}, else: :ok
  end

  defp validate_id(id, :plan), do: {:error, {:invalid_plan_id, id}}

  @spec validate_version(term()) :: :ok | {:error, term()}
  defp validate_version(version) when is_integer(version) and version > 0, do: :ok
  defp validate_version(version), do: {:error, {:invalid_plan_version, version}}

  @spec validate_source(term()) :: :ok | {:error, term()}
  defp validate_source(source) when source in @sources, do: :ok
  defp validate_source(source), do: {:error, {:invalid_plan_source, source}}

  @spec validate_revision_history(term()) :: :ok | {:error, term()}
  defp validate_revision_history(revisions) when is_list(revisions) do
    if Enum.all?(revisions, &is_map/1),
      do: :ok,
      else: {:error, {:invalid_plan_revision_history, revisions}}
  end

  defp validate_revision_history(revisions),
    do: {:error, {:invalid_plan_revision_history, revisions}}

  @spec valid_step_status?(term()) :: boolean()
  defp valid_step_status?(%Step{status: status}), do: status in @step_statuses

  @spec valid_step_attempts?(term()) :: boolean()
  defp valid_step_attempts?(%Step{attempts: attempts}),
    do: is_integer(attempts) and attempts >= 0

  @spec valid_id?(term()) :: boolean()
  defp valid_id?(id) when is_binary(id), do: String.trim(id) != ""
  defp valid_id?(_id), do: false

  @spec value(map(), atom(), term()) :: term()
  defp value(attrs, key, default \\ nil) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key), default)
    end
  end
end
