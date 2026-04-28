defmodule SpectreDirective.AL do
  @moduledoc """
  Minimal built-in Action Language resolver.

  When SpectreKinetic is available and configured, callers can resolve through
  `SpectreDirective.KineticAdapter`. This module keeps Directive useful alone.
  """

  alias SpectreDirective.Jobs.{
    Agent,
    CodexAgent,
    HostCommand,
    UserCommand,
    Workflow,
    WorkspaceCommand
  }

  @doc """
  Resolves an existing job struct, AL string, or list of AL strings into a job.
  """
  @spec resolve(term(), keyword()) :: {:ok, term()} | {:error, term()}
  def resolve(job, _opts) when is_struct(job), do: {:ok, job}

  def resolve(lines, opts) when is_list(lines) do
    with {:ok, jobs} <- resolve_many(lines, opts) do
      {:ok, %Workflow{steps: jobs, mode: Keyword.get(opts, :mode, :sequential)}}
    end
  end

  def resolve(al, opts) when is_binary(al) do
    text = String.trim(al)
    slots = parse_slots(text)
    upper = String.upcase(text)

    cond do
      String.starts_with?(upper, "RUN HOST COMMAND") ->
        {:ok,
         %HostCommand{
           command: slot(slots, "COMMAND"),
           cwd: slot(slots, "CWD"),
           timeout_ms: int_slot(slots, "TIMEOUT_MS", 60_000),
           allow_host_execution:
             bool_slot(slots, "ALLOW", Keyword.get(opts, :allow_host_execution, false))
         }}

      String.starts_with?(upper, "RUN COMMAND") ->
        {:ok,
         %WorkspaceCommand{
           command: slot(slots, "COMMAND"),
           cwd: slot(slots, "CWD"),
           timeout_ms: int_slot(slots, "TIMEOUT_MS", 60_000)
         }}

      String.starts_with?(upper, "RUN USER COMMAND") ->
        {:ok,
         %UserCommand{
           command: slot(slots, "COMMAND"),
           user: slot(slots, "USER"),
           group: slot(slots, "GROUP"),
           cwd: slot(slots, "CWD"),
           timeout_ms: int_slot(slots, "TIMEOUT_MS", 60_000)
         }}

      String.starts_with?(upper, "RUN CODEX TASK") ->
        {:ok,
         %CodexAgent{
           prompt: slot(slots, "PROMPT") || slot(slots, "TASK"),
           cwd: slot(slots, "CWD"),
           model: slot(slots, "MODEL"),
           timeout_ms: int_slot(slots, "TIMEOUT_MS", 3_600_000)
         }}

      String.starts_with?(upper, "SPAWN AGENT") ->
        {:ok,
         %Agent{
           prompt: slot(slots, "PROMPT") || slot(slots, "TASK"),
           model: slot(slots, "MODEL"),
           role: slot(slots, "ROLE"),
           adapter: Keyword.get(opts, :agent_adapter),
           timeout_ms: int_slot(slots, "TIMEOUT_MS", 300_000)
         }}

      true ->
        {:error, {:unsupported_al, al}}
    end
  end

  def resolve(other, _opts), do: {:error, {:unsupported_input, other}}

  @doc """
  Extracts `KEY=value` or `KEY="value"` slots from one AL instruction.
  """
  @spec parse_slots(binary()) :: map()
  def parse_slots(text) when is_binary(text) do
    ~r/([A-Za-z0-9_]+)\s*=\s*"([^"]*)"|([A-Za-z0-9_]+)\s*=\s*([^\s]+)/
    |> Regex.scan(text, capture: :all_but_first)
    |> Enum.reduce(%{}, fn
      [quoted_key, quoted_value, "", ""], acc ->
        Map.put(acc, String.upcase(quoted_key), quoted_value)

      ["", "", bare_key, bare_value], acc ->
        Map.put(acc, String.upcase(bare_key), bare_value)

      parts, acc ->
        case Enum.reject(parts, &(&1 == "")) do
          [key, value] -> Map.put(acc, String.upcase(key), value)
          _ -> acc
        end
    end)
  end

  @spec resolve_many([term()], keyword()) :: {:ok, [term()]} | {:error, term()}
  defp resolve_many(lines, opts) do
    lines
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, jobs} ->
      case resolve(line, opts) do
        {:ok, job} -> {:cont, {:ok, jobs ++ [job]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec slot(map(), binary()) :: binary() | nil
  defp slot(slots, key), do: Map.get(slots, key)

  @spec int_slot(map(), binary(), pos_integer()) :: pos_integer()
  defp int_slot(slots, key, default) do
    case Integer.parse(Map.get(slots, key, "")) do
      {value, ""} when value > 0 -> value
      _ -> default
    end
  end

  @spec bool_slot(map(), binary(), boolean()) :: boolean()
  defp bool_slot(slots, key, default) do
    case String.downcase(Map.get(slots, key, "")) do
      "true" -> true
      "yes" -> true
      "1" -> true
      "false" -> false
      "no" -> false
      "0" -> false
      _ -> default
    end
  end
end
