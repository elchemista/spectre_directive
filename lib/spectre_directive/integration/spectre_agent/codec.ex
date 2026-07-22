defmodule SpectreDirective.Integration.SpectreAgent.Codec do
  @moduledoc false

  @jason_module :"Elixir.Jason"

  @doc false
  @spec encode(term()) :: {:ok, binary()} | {:error, term()}
  def encode(value) do
    if Code.ensure_loaded?(@jason_module) do
      # Jason is supplied by Spectre and remains optional for this package.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(@jason_module, :encode, [json_safe(value)])
    else
      {:error, :json_codec_unavailable}
    end
  end

  @doc false
  @spec decode(term()) :: {:ok, term()} | {:error, term()}
  def decode(text) when is_binary(text) do
    if Code.ensure_loaded?(@jason_module) do
      # Jason is supplied by Spectre and remains optional for this package.
      # credo:disable-for-next-line Credo.Check.Refactor.Apply
      apply(@jason_module, :decode, [json_body(text)])
    else
      {:error, :json_codec_unavailable}
    end
  end

  def decode(value), do: {:error, {:expected_json_response, value}}

  @spec json_body(binary()) :: binary()
  defp json_body(text) do
    text = String.trim(text)

    case Regex.run(~r/```(?:json)?\s*(.*?)```/s, text, capture: :all_but_first) do
      [json] -> String.trim(json)
      nil -> extract_json_object(text)
    end
  end

  @spec extract_json_object(binary()) :: binary()
  defp extract_json_object(text) do
    case Regex.run(~r/\{.*\}/s, text) do
      [json] -> json
      nil -> text
    end
  end

  @spec json_safe(term()) :: term()
  defp json_safe(value) when is_nil(value) or is_boolean(value) or is_number(value), do: value
  defp json_safe(value) when is_binary(value), do: value
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp json_safe(%_{} = value) do
    value
    |> Map.from_struct()
    |> Map.put(:__struct__, inspect(value.__struct__))
    |> json_safe()
  end

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {json_key(key), json_safe(item)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: value |> Tuple.to_list() |> json_safe()

  defp json_safe(value),
    do: inspect(value, limit: 50, printable_limit: 2_000, charlists: :as_lists)

  @spec json_key(term()) :: binary()
  defp json_key(key) when is_binary(key), do: key
  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: inspect(key)
end
