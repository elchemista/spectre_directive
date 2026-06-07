defmodule SpectreDirective.DSL.Builder do
  @moduledoc false

  alias SpectreDirective.Mission
  alias SpectreDirective.MissionBlueprint
  alias SpectreDirective.Step

  @directive_attrs [
    :__spectre_mission_goal__,
    :__spectre_context__,
    :__spectre_success__,
    :__spectre_mode__,
    :__spectre_memory__,
    :__spectre_capability_rules__,
    :__spectre_strategies__,
    :__spectre_alignment_rules__,
    :__spectre_correction_rules__,
    :__spectre_steps__
  ]

  @step_attrs [
    :__spectre_step_kind__,
    :__spectre_step_flexibility__,
    :__spectre_step_purpose__,
    :__spectre_step_reason__,
    :__spectre_step_prompt__,
    :__spectre_step_expects__,
    :__spectre_step_done_when__,
    :__spectre_step_risk__,
    :__spectre_step_capability__,
    :__spectre_step_input__,
    :__spectre_step_metadata__
  ]

  @valid_flexibilities [:locked, :guided, :optional, :agentic]
  @valid_kinds [
    :remember,
    :observe,
    :investigate,
    :act,
    :verify,
    :summarize,
    :ask,
    :decide,
    :guard,
    :correct,
    :finish
  ]
  @valid_risks [:low, :medium, :high, :critical]

  @spec register(module()) :: :ok
  def register(module) do
    Module.register_attribute(module, :__spectre_directives__, accumulate: true)
    Module.register_attribute(module, :__spectre_strategies__, accumulate: true)
    Module.register_attribute(module, :__spectre_alignment_rules__, accumulate: true)
    Module.register_attribute(module, :__spectre_correction_rules__, accumulate: true)
    Module.register_attribute(module, :__spectre_steps__, accumulate: true)
    :ok
  end

  @spec reset_directive(module()) :: :ok
  def reset_directive(module) do
    Enum.each(@directive_attrs, &Module.delete_attribute(module, &1))
    Module.put_attribute(module, :__spectre_memory__, %{})

    Module.put_attribute(module, :__spectre_capability_rules__, %{
      required: [],
      allowed: [],
      denied: []
    })

    :ok
  end

  @spec reset_step(module()) :: :ok
  def reset_step(module) do
    Enum.each(@step_attrs, &Module.delete_attribute(module, &1))
    :ok
  end

  @spec put(module(), atom(), term()) :: :ok
  def put(module, attr, value) do
    Module.put_attribute(module, attr, value)
    :ok
  end

  @spec add_strategy(module(), atom()) :: :ok
  def add_strategy(module, strategy),
    do: Module.put_attribute(module, :__spectre_strategies__, strategy)

  @spec add_alignment_rule(module(), term()) :: :ok
  def add_alignment_rule(module, rule),
    do: Module.put_attribute(module, :__spectre_alignment_rules__, rule)

  @spec add_correction_rule(module(), term()) :: :ok
  def add_correction_rule(module, rule),
    do: Module.put_attribute(module, :__spectre_correction_rules__, rule)

  @spec put_memory(module(), atom(), term()) :: :ok
  def put_memory(module, key, value) do
    memory = Module.get_attribute(module, :__spectre_memory__) || %{}

    Module.put_attribute(
      module,
      :__spectre_memory__,
      Map.update(memory, key, List.wrap(value), &(List.wrap(&1) ++ List.wrap(value)))
    )

    :ok
  end

  @spec put_capability_rule(module(), :required | :allowed | :denied, term()) :: :ok
  def put_capability_rule(module, key, value) do
    rules =
      Module.get_attribute(module, :__spectre_capability_rules__) ||
        %{required: [], allowed: [], denied: []}

    Module.put_attribute(
      module,
      :__spectre_capability_rules__,
      Map.update!(rules, key, &Enum.uniq(&1 ++ List.wrap(value)))
    )

    :ok
  end

  @spec add_step_from_module(module(), binary()) :: :ok
  def add_step_from_module(module, title) do
    attrs = step_attrs(module, title)
    validate_step!(module, title, attrs)
    step = Step.new(title, Keyword.put(attrs, :source, :authored))

    Module.put_attribute(module, :__spectre_steps__, step)
    :ok
  end

  @spec blueprint_from_module(module(), binary()) :: MissionBlueprint.t()
  def blueprint_from_module(module, name) do
    memory = Module.get_attribute(module, :__spectre_memory__) || %{}

    attrs = [
      name: name,
      mission:
        Mission.new(%{
          goal: Module.get_attribute(module, :__spectre_mission_goal__),
          context: Module.get_attribute(module, :__spectre_context__),
          success: Module.get_attribute(module, :__spectre_success__),
          memory_scope: memory_scope(memory)
        }),
      mode: Module.get_attribute(module, :__spectre_mode__) || :guided,
      source: :authored,
      memory: memory,
      capability_rules:
        Module.get_attribute(module, :__spectre_capability_rules__) ||
          %{required: [], allowed: [], denied: []},
      strategies:
        Module.get_attribute(module, :__spectre_strategies__) |> List.wrap() |> Enum.reverse(),
      alignment_rules:
        Module.get_attribute(module, :__spectre_alignment_rules__)
        |> List.wrap()
        |> Enum.reverse(),
      correction_rules:
        Module.get_attribute(module, :__spectre_correction_rules__)
        |> List.wrap()
        |> Enum.reverse(),
      steps: Module.get_attribute(module, :__spectre_steps__) |> List.wrap() |> Enum.reverse()
    ]

    validate_directive!(module, name, attrs)
    MissionBlueprint.new(attrs)
  end

  @spec step_attrs(module(), binary()) :: keyword()
  defp step_attrs(module, _title) do
    [
      kind: Module.get_attribute(module, :__spectre_step_kind__) || :investigate,
      flexibility: Module.get_attribute(module, :__spectre_step_flexibility__) || :guided,
      purpose: Module.get_attribute(module, :__spectre_step_purpose__),
      reason: Module.get_attribute(module, :__spectre_step_reason__),
      prompt: Module.get_attribute(module, :__spectre_step_prompt__),
      expected_output: Module.get_attribute(module, :__spectre_step_expects__),
      done_condition: Module.get_attribute(module, :__spectre_step_done_when__),
      risk: Module.get_attribute(module, :__spectre_step_risk__) || :low,
      required_capability: Module.get_attribute(module, :__spectre_step_capability__),
      input: Module.get_attribute(module, :__spectre_step_input__),
      metadata: Module.get_attribute(module, :__spectre_step_metadata__) || %{}
    ]
  end

  @spec validate_step!(module(), binary(), keyword()) :: :ok | no_return()
  defp validate_step!(module, title, attrs) do
    errors =
      []
      |> require_binary(attrs[:purpose], "purpose/1 is required")
      |> require_member(
        attrs[:kind],
        @valid_kinds,
        "kind/1 must be one of #{inspect(@valid_kinds)}"
      )
      |> require_member(
        attrs[:flexibility],
        @valid_flexibilities,
        "flexibility/1 must be one of #{inspect(@valid_flexibilities)}"
      )
      |> require_member(
        attrs[:risk],
        @valid_risks,
        "risk/1 must be one of #{inspect(@valid_risks)}"
      )

    raise_validation_errors!(errors, "step #{inspect(title)} in #{inspect(module)}")
  end

  @spec validate_directive!(module(), binary(), keyword()) :: :ok | no_return()
  defp validate_directive!(module, name, attrs) do
    mission = Keyword.fetch!(attrs, :mission)
    steps = Keyword.fetch!(attrs, :steps)

    errors =
      []
      |> require_binary(mission.goal, "mission/1 is required")
      |> require_binary(mission.context, "context/1 is required")
      |> require_binary(mission.success_criteria, "success/1 is required")
      |> require_steps(steps)

    raise_validation_errors!(errors, "directive #{inspect(name)} in #{inspect(module)}")
  end

  @spec require_binary([binary()], term(), binary()) :: [binary()]
  defp require_binary(errors, value, message) when is_binary(value) do
    if String.trim(value) == "", do: [message | errors], else: errors
  end

  defp require_binary(errors, _value, message), do: [message | errors]

  @spec require_member([binary()], term(), [term()], binary()) :: [binary()]
  defp require_member(errors, value, allowed, message) do
    if value in allowed, do: errors, else: [message | errors]
  end

  @spec require_steps([binary()], [Step.t()]) :: [binary()]
  defp require_steps(errors, [_step | _steps]), do: errors
  defp require_steps(errors, []), do: ["at least one step/2 block is required" | errors]

  @spec raise_validation_errors!([binary()], binary()) :: :ok | no_return()
  defp raise_validation_errors!([], _subject), do: :ok

  defp raise_validation_errors!(errors, subject) do
    message = Enum.reverse(errors) |> Enum.join("; ")
    raise ArgumentError, "invalid SpectreDirective #{subject}: #{message}"
  end

  @spec memory_scope(map()) :: term()
  defp memory_scope(%{scope: [scope | _]}), do: scope
  defp memory_scope(%{scope: scope}), do: scope
  defp memory_scope(_memory), do: nil
end
