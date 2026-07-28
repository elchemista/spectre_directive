defmodule Spectre.Directive.Extension do
  @moduledoc false

  @behaviour Spectre.Extension

  alias SpectreDirective.Integration.SpectreAgent.TurnHandler

  @handler_option_keys [
    :store_opts,
    :store_namespace,
    :directive_key,
    :presenter,
    :presenter_opts,
    :await_timeout
  ]

  @impl true
  def id, do: :directive

  @impl true
  def api_version, do: 1

  @impl true
  def compile(_owner, opts) do
    case Keyword.fetch(opts, :stack_config) do
      {:ok, config} when is_map(config) ->
        {:ok, config}

      {:ok, invalid} ->
        {:error, {:invalid_directive_stack_config, invalid}}

      :error ->
        {:ok,
         %{
           options: opts,
           store: Keyword.get(opts, :store),
           clock: Keyword.get(opts, :clock),
           resident_runs: Keyword.get(opts, :resident_runs)
         }}
    end
  end

  @impl true
  def agent_config(config) when is_map(config) do
    handler_opts =
      config
      |> Map.get(:options, [])
      |> Keyword.take(@handler_option_keys)
      |> maybe_put(:store, Map.get(config, :store))
      |> maybe_put(:clock, Map.get(config, :clock))
      |> maybe_put(:resident_runs, Map.get(config, :resident_runs))

    [
      directive: config,
      turn_handlers: [{TurnHandler, handler_opts}]
    ]
  end

  @spec maybe_put(keyword(), atom(), term()) :: keyword()
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
