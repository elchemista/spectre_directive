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
    :__spectre_on_complete__,
    :__spectre_directive_metadata__,
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
    :__spectre_step_input__,
    :__spectre_step_metadata__,
    :__spectre_step_invoke__,
    :__spectre_step_policy__
  ]

  @valid_flexibilities [:locked, :guided, :optional, :agentic]
  @valid_risks [:low, :medium, :high, :critical]
  @valid_modes [:fixed, :guided, :autonomous, :strict, :adaptive]

  @doc false
  @spec register(module()) :: :ok
  def register(module) do
    Module.register_attribute(module, :__spectre_directives__, accumulate: true)
    Module.register_attribute(module, :__spectre_steps__, accumulate: true)
    :ok
  end

  @doc false
  @spec reset_directive(module()) :: :ok
  def reset_directive(module) do
    Enum.each(@directive_attrs, &Module.delete_attribute(module, &1))
    :ok
  end

  @doc false
  @spec reset_step(module()) :: :ok
  def reset_step(module) do
    Enum.each(@step_attrs, &Module.delete_attribute(module, &1))
    :ok
  end

  @doc false
  @spec put(module(), atom(), term()) :: :ok
  def put(module, attr, value) do
    Module.put_attribute(module, attr, value)
    :ok
  end

  @doc false
  @spec add_step_from_module(module(), binary()) :: :ok
  def add_step_from_module(module, title) do
    attrs = step_attrs(module)
    validate_step!(module, title, attrs)
    Module.put_attribute(module, :__spectre_steps__, Step.new(title, attrs))
    :ok
  end

  @doc false
  @spec blueprint_from_module(module(), binary()) :: MissionBlueprint.t()
  def blueprint_from_module(module, name) do
    attrs = [
      name: name,
      mission:
        Mission.new(%{
          goal: Module.get_attribute(module, :__spectre_mission_goal__),
          context: Module.get_attribute(module, :__spectre_context__),
          success: Module.get_attribute(module, :__spectre_success__)
        }),
      mode: Module.get_attribute(module, :__spectre_mode__) || :guided,
      source: :authored,
      steps: Module.get_attribute(module, :__spectre_steps__) |> List.wrap() |> Enum.reverse(),
      on_complete: Module.get_attribute(module, :__spectre_on_complete__),
      metadata: Module.get_attribute(module, :__spectre_directive_metadata__) || %{}
    ]

    validate_directive!(module, name, attrs)
    MissionBlueprint.new(attrs)
  end

  @spec step_attrs(module()) :: keyword()
  defp step_attrs(module) do
    [
      kind: Module.get_attribute(module, :__spectre_step_kind__) || :investigate,
      flexibility: Module.get_attribute(module, :__spectre_step_flexibility__) || :guided,
      purpose: Module.get_attribute(module, :__spectre_step_purpose__),
      reason: Module.get_attribute(module, :__spectre_step_reason__),
      prompt: Module.get_attribute(module, :__spectre_step_prompt__),
      expected_output: Module.get_attribute(module, :__spectre_step_expects__),
      done_condition: Module.get_attribute(module, :__spectre_step_done_when__),
      risk: Module.get_attribute(module, :__spectre_step_risk__) || :low,
      input: Module.get_attribute(module, :__spectre_step_input__),
      invoke: Module.get_attribute(module, :__spectre_step_invoke__),
      policy: Module.get_attribute(module, :__spectre_step_policy__),
      metadata: Module.get_attribute(module, :__spectre_step_metadata__) || %{},
      source: :authored
    ]
  end

  @spec validate_step!(module(), binary(), keyword()) :: :ok | no_return()
  defp validate_step!(module, title, attrs) do
    errors =
      []
      |> require_non_empty(title, "step title must not be empty")
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

    errors =
      []
      |> require_non_empty(mission.goal, "mission/1 or objective/1 is required")
      |> require_member(
        Keyword.fetch!(attrs, :mode),
        @valid_modes,
        "mode/1 must be one of #{inspect(@valid_modes)}"
      )

    raise_validation_errors!(errors, "directive #{inspect(name)} in #{inspect(module)}")
  end

  @spec require_non_empty([binary()], term(), binary()) :: [binary()]
  defp require_non_empty(errors, value, message) when is_binary(value) do
    if String.trim(value) == "", do: [message | errors], else: errors
  end

  defp require_non_empty(errors, _value, message), do: [message | errors]

  @spec require_member([binary()], term(), [term()], binary()) :: [binary()]
  defp require_member(errors, value, allowed, message) do
    if value in allowed, do: errors, else: [message | errors]
  end

  @spec raise_validation_errors!([binary()], binary()) :: :ok | no_return()
  defp raise_validation_errors!([], _subject), do: :ok

  defp raise_validation_errors!(errors, subject) do
    raise ArgumentError,
          "invalid SpectreDirective #{subject}: #{errors |> Enum.reverse() |> Enum.join("; ")}"
  end
end
