defmodule SpectreDirective.RequestHandler do
  @moduledoc """
  Adapter for hosts that want the optional runtime to resolve arbitrary
  requests. Manual or asynchronous UI hosts should instead subscribe to events
  and call `respond/3` when the user eventually answers.
  """

  alias SpectreDirective.Request

  @type target :: (Request.t() -> term()) | module() | {module(), keyword()}

  @callback handle_request(Request.t(), keyword()) :: term()

  @doc "Calls a request handler from a supervised worker process."
  @spec call(target(), Request.t(), keyword()) :: term()
  def call(target, request, opts \\ [])

  def call(target, %Request{} = request, opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: dispatch(target, request, opts),
      else: {:error, {:invalid_request_handler_options, opts}}
  end

  def call(_target, %Request{}, opts),
    do: {:error, {:invalid_request_handler_options, opts}}

  @spec dispatch(target(), Request.t(), keyword()) :: term()
  defp dispatch(function, request, _opts) when is_function(function, 1),
    do: function.(request)

  defp dispatch({module, adapter_opts} = target, request, opts)
       when is_atom(module) and is_list(adapter_opts) do
    if Keyword.keyword?(adapter_opts),
      do: module.handle_request(request, Keyword.merge(adapter_opts, opts)),
      else: {:error, {:invalid_request_handler, target}}
  end

  defp dispatch(module, request, opts) when is_atom(module),
    do: module.handle_request(request, opts)

  defp dispatch(target, _request, _opts), do: {:error, {:invalid_request_handler, target}}
end
