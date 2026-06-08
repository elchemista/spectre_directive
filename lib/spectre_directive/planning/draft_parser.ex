defmodule SpectreDirective.Planning.DraftParser do
  @moduledoc """
  Parses an agent-written planning draft into a `SpectreDirective.Plan`.

  The draft format is intentionally text-first. It is not JSON and it is not a
  data contract masquerading as prose. The parser looks for numbered steps or
  `Step:` headings, then reads simple labels under each step.

      Plan:
      1. Observe signup entry
         kind: observe
         purpose: Understand the available signup options.
         expects: Visible methods and required fields.

      ### Step 2: Verify signup result
      **Kind:** verify
      **Purpose:** Decide whether the mission succeeded.

  Unknown labels are kept in step metadata. Unknown enum values fall back to
  conservative defaults instead of creating atoms from model text.
  """

  alias SpectreDirective.Plan
  alias SpectreDirective.Step

  @type parse_result :: {:ok, Plan.t()} | {:error, :no_steps}
  @type next_step_result :: {:ok, Step.t()} | {:finish, binary()} | {:error, :no_steps}
  @type field_key :: atom() | {:metadata, binary()}
  @type step_draft :: %{required(:title) => binary(), optional(atom()) => binary() | map()}
  @type parser_state :: %{
          required(:steps) => [step_draft()],
          required(:current) => step_draft() | nil,
          required(:last_field) => field_key() | nil
        }

  @step_start ~r/^\s*(?:#+\s*)?(?:[-*]\s*)?(?:(?:\d+\s*[\).:-])|(?:step(?:\s+\d+)?\s*[:\-.]))\s*(.+)$/i
  @field ~r/^\s*(?:[-*]\s*)?[\*_`]*([a-zA-Z][a-zA-Z _-]*)[\*_`]*\s*:[\*_`]*\s*(.+)$/
  @finish ~r/^\s*(?:finish|finished|no more steps)\b\s*:?\s*(.*)$/im

  @kind_values %{
    "remember" => :remember,
    "observe" => :observe,
    "investigate" => :investigate,
    "act" => :act,
    "verify" => :verify,
    "summarize" => :summarize,
    "ask" => :ask,
    "decide" => :decide,
    "guard" => :guard,
    "correct" => :correct,
    "finish" => :finish
  }

  @flexibility_values %{
    "locked" => :locked,
    "guided" => :guided,
    "optional" => :optional,
    "agentic" => :agentic
  }

  @risk_values %{
    "none" => :none,
    "low" => :low,
    "medium" => :medium,
    "high" => :high,
    "critical" => :critical
  }

  @doc """
  Parses a textual planning draft.
  """
  @spec parse(binary()) :: parse_result()
  def parse(draft) when is_binary(draft) do
    draft
    |> lines()
    |> Enum.reduce(initial_state(), &parse_line/2)
    |> finalize_state()
    |> build_plan()
  end

  @doc """
  Parses one guided-planning response.

  The model may return either one step or `Finish: reason`.
  """
  @spec parse_next_step(binary()) :: next_step_result()
  def parse_next_step(draft) when is_binary(draft) do
    case finish_reason(draft) do
      nil -> first_step(draft)
      reason -> {:finish, reason}
    end
  end

  @spec lines(binary()) :: [binary()]
  defp lines(draft) do
    draft
    |> String.replace("\r\n", "\n")
    |> String.split("\n")
  end

  @spec initial_state() :: parser_state()
  defp initial_state, do: %{steps: [], current: nil, last_field: nil}

  @spec parse_line(binary(), parser_state()) :: parser_state()
  defp parse_line(line, state) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        state

      step_title = step_title(trimmed) ->
        start_step(state, step_title)

      field = field(trimmed) ->
        put_field(state, field)

      true ->
        append_to_last_field(state, trimmed)
    end
  end

  @spec step_title(binary()) :: binary() | nil
  defp step_title(line) do
    case Regex.run(@step_start, line) do
      [_match, title] -> clean_title(title)
      nil -> nil
    end
  end

  @spec finish_reason(binary()) :: binary() | nil
  defp finish_reason(draft) do
    case Regex.run(@finish, draft) do
      [_match, ""] -> "planner said finish"
      [_match, reason] -> String.trim(reason)
      nil -> nil
    end
  end

  @spec first_step(binary()) :: next_step_result()
  defp first_step(draft) do
    case parse(draft) do
      {:ok, %Plan{steps: [step | _steps]}} -> {:ok, step}
      {:error, :no_steps} -> {:error, :no_steps}
    end
  end

  @spec field(binary()) :: {field_key(), binary()} | nil
  defp field(line) do
    case Regex.run(@field, line) do
      [_match, key, value] -> {field_name(key), String.trim(value)}
      nil -> nil
    end
  end

  @spec clean_title(binary()) :: binary()
  defp clean_title(title) do
    title
    |> String.trim()
    |> String.trim_leading("-")
    |> String.trim()
    |> String.trim("*")
    |> String.trim("`")
    |> String.trim()
  end

  @spec field_name(binary()) :: field_key()
  defp field_name(key) do
    key
    |> String.downcase()
    |> String.replace(["-", " "], "_")
    |> known_field()
  end

  @spec known_field(binary()) :: field_key()
  defp known_field("expected_output"), do: :expected_output
  defp known_field("expects"), do: :expected_output
  defp known_field("expect"), do: :expected_output
  defp known_field("done"), do: :done_condition
  defp known_field("done_when"), do: :done_condition
  defp known_field("done_condition"), do: :done_condition
  defp known_field("capability"), do: :required_capability
  defp known_field("required_capability"), do: :required_capability
  defp known_field("why"), do: :purpose
  defp known_field("kind"), do: :kind
  defp known_field("purpose"), do: :purpose
  defp known_field("reason"), do: :reason
  defp known_field("risk"), do: :risk
  defp known_field("flexibility"), do: :flexibility
  defp known_field("owner"), do: :owner
  defp known_field("prompt"), do: :prompt
  defp known_field(other), do: {:metadata, other}

  @spec start_step(parser_state(), binary()) :: parser_state()
  defp start_step(state, title) do
    state
    |> flush_current()
    |> Map.merge(%{current: %{title: title}, last_field: nil})
  end

  @spec put_field(parser_state(), {atom() | {:metadata, binary()}, binary()}) :: parser_state()
  defp put_field(%{current: nil} = state, _field), do: state

  defp put_field(state, {{:metadata, key}, value}) do
    metadata = Map.get(state.current, :metadata, %{})
    current = Map.put(state.current, :metadata, Map.put(metadata, key, value))
    %{state | current: current, last_field: {:metadata, key}}
  end

  defp put_field(state, {key, value}) when is_atom(key) do
    %{state | current: Map.put(state.current, key, value), last_field: key}
  end

  @spec append_to_last_field(parser_state(), binary()) :: parser_state()
  defp append_to_last_field(%{current: nil} = state, _line), do: state
  defp append_to_last_field(%{last_field: nil} = state, _line), do: state

  defp append_to_last_field(%{last_field: {:metadata, key}} = state, line) do
    metadata = Map.get(state.current, :metadata, %{})
    value = append_text(Map.get(metadata, key, ""), line)
    current = Map.put(state.current, :metadata, Map.put(metadata, key, value))
    %{state | current: current}
  end

  defp append_to_last_field(state, line) do
    value = state.current |> Map.get(state.last_field, "") |> append_text(line)
    %{state | current: Map.put(state.current, state.last_field, value)}
  end

  @spec append_text(binary(), binary()) :: binary()
  defp append_text("", line), do: line
  defp append_text(value, line), do: value <> " " <> line

  @spec finalize_state(parser_state()) :: [step_draft()]
  defp finalize_state(state), do: state |> flush_current() |> Map.fetch!(:steps) |> Enum.reverse()

  @spec flush_current(parser_state()) :: parser_state()
  defp flush_current(%{current: nil} = state), do: state

  defp flush_current(%{current: current, steps: steps} = state) do
    %{state | steps: [current | steps], current: nil, last_field: nil}
  end

  @spec build_plan([step_draft()]) :: parse_result()
  defp build_plan([]), do: {:error, :no_steps}

  defp build_plan(steps) do
    plan =
      steps
      |> Enum.map(&build_step/1)
      |> Plan.new(source: :agent_generated, reason: "Parsed from textual planning draft.")

    {:ok, plan}
  end

  @spec build_step(step_draft()) :: Step.t()
  defp build_step(attrs) do
    Step.new(
      title: Map.fetch!(attrs, :title),
      kind: enum_value(attrs, :kind, @kind_values, :investigate),
      purpose: Map.get(attrs, :purpose),
      reason: Map.get(attrs, :reason),
      required_capability: Map.get(attrs, :required_capability),
      expected_output: Map.get(attrs, :expected_output),
      done_condition: Map.get(attrs, :done_condition),
      risk: enum_value(attrs, :risk, @risk_values, :low),
      owner: Map.get(attrs, :owner),
      prompt: Map.get(attrs, :prompt),
      flexibility: enum_value(attrs, :flexibility, @flexibility_values, :guided),
      source: :generated,
      metadata: Map.get(attrs, :metadata, %{})
    )
  end

  @spec enum_value(map(), atom(), %{binary() => atom()}, atom()) :: atom()
  defp enum_value(attrs, key, values, default) do
    attrs
    |> Map.get(key, "")
    |> String.downcase()
    |> String.trim()
    |> then(&Map.get(values, &1, default))
  end
end
