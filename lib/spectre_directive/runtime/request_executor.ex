defmodule SpectreDirective.Runtime.RequestExecutor do
  @moduledoc false

  alias SpectreDirective.Invoker
  alias SpectreDirective.Policy
  alias SpectreDirective.Reasoner
  alias SpectreDirective.Request
  alias SpectreDirective.RequestHandler
  alias SpectreDirective.Runtime.State

  @type executor ::
          {:reasoner, Reasoner.target()}
          | {:invoker, Invoker.target()}
          | {:policy, Policy.target()}
          | {:handler, RequestHandler.target()}

  @type result ::
          {:spectre_worker_result, term()}
          | {:spectre_worker_error, term()}

  @doc false
  @spec select(State.t(), Request.t()) :: executor() | nil
  def select(%State{execution: :manual}, _request), do: nil
  def select(%State{execution: {:handler, handler}}, _request), do: {:handler, handler}

  def select(%State{execution: :auto}, %Request{kind: :reason, target: target})
      when not is_nil(target),
      do: {:reasoner, target}

  def select(%State{execution: :auto}, %Request{kind: :invoke, target: target})
      when not is_nil(target),
      do: {:invoker, target}

  def select(%State{execution: :auto, policy_handler: handler}, %Request{kind: :policy})
      when not is_nil(handler),
      do: {:policy, handler}

  def select(%State{execution: :auto, request_handler: handler}, _request)
      when not is_nil(handler),
      do: {:handler, handler}

  def select(%State{}, %Request{}), do: nil

  @doc false
  @spec execute(executor(), Request.t()) :: result()
  def execute(executor, %Request{} = request) do
    {:spectre_worker_result, dispatch(executor, request)}
  rescue
    exception ->
      {:spectre_worker_error, {:exception, exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:spectre_worker_error, {kind, reason}}
  end

  @spec dispatch(executor(), Request.t()) :: term()
  defp dispatch({:reasoner, target}, %Request{} = request) do
    Reasoner.call(target, request.context, List.wrap(request.payload[:opts]))
  end

  defp dispatch({:invoker, target}, %Request{} = request),
    do: Invoker.call(target, request.context)

  defp dispatch({:policy, handler}, %Request{} = request) do
    Policy.call(handler, request.payload[:policy], request.context)
  end

  defp dispatch({:handler, handler}, %Request{} = request),
    do: RequestHandler.call(handler, request)
end
