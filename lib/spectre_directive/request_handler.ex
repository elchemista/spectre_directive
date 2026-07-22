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

  def call(function, request, _opts) when is_function(function, 1), do: function.(request)

  def call({module, adapter_opts}, request, opts)
      when is_atom(module) and is_list(adapter_opts),
      do: module.handle_request(request, Keyword.merge(adapter_opts, opts))

  def call(module, request, opts) when is_atom(module),
    do: module.handle_request(request, opts)

  def call(target, _request, _opts), do: {:error, {:invalid_request_handler, target}}
end
