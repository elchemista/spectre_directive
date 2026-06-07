defmodule SpectreDirective.Planning.TextProvider do
  @moduledoc """
  Normalizes the host application's model connection.

  A host app should not need a full planner module just to try the library. The
  simplest integration is a one-argument function that receives the prompt and
  returns text:

      SpectreDirective.create(%{
        mission: "Check signup",
        model: &MyApp.Model.complete/1,
        mode: :guided
      })

  Larger applications can still pass a module with `draft_plan/2` when they need
  richer routing, telemetry, retries, or provider-specific options.
  """

  alias SpectreDirective.Planning.Request

  @type provider ::
          module()
          | {:prompt_function, (binary() -> result())}
          | {:request_function, (Request.t(), keyword() -> result())}

  @type result :: binary() | {:ok, binary()} | {:error, term()}

  @doc """
  Finds a text provider in planner options.
  """
  @spec from_opts(keyword()) :: provider() | nil | :none
  def from_opts(opts) when is_list(opts) do
    cond do
      Keyword.has_key?(opts, :planner) ->
        Keyword.fetch!(opts, :planner)

      Keyword.has_key?(opts, :planning_adapter) ->
        Keyword.fetch!(opts, :planning_adapter)

      model = prompt_function(opts) ->
        model

      model = request_function(opts) ->
        model

      true ->
        nil
    end
  end

  @doc """
  Calls a configured provider with a planning request.
  """
  @spec call(provider(), Request.t(), keyword()) :: term()
  def call({:prompt_function, function}, %Request{} = request, _opts) do
    function.(request.prompt)
  rescue
    error -> {:error, {:planning_model_failed, error}}
  catch
    kind, reason -> {:error, {:planning_model_failed, {kind, reason}}}
  end

  def call({:request_function, function}, %Request{} = request, opts) do
    function.(request, opts)
  rescue
    error -> {:error, {:planning_model_failed, error}}
  catch
    kind, reason -> {:error, {:planning_model_failed, {kind, reason}}}
  end

  def call(provider, %Request{} = request, opts) when is_atom(provider) do
    provider.draft_plan(request, opts)
  rescue
    error -> {:error, {:planner_failed, provider, error}}
  catch
    kind, reason -> {:error, {:planner_failed, provider, {kind, reason}}}
  end

  def call(provider, %Request{}, _opts) do
    {:error, {:invalid_text_provider, provider}}
  end

  @spec prompt_function(keyword()) :: provider() | nil
  defp prompt_function(opts) do
    model = Keyword.get(opts, :planning_model)

    if is_function(model, 1), do: {:prompt_function, model}
  end

  @spec request_function(keyword()) :: provider() | nil
  defp request_function(opts) do
    model = Keyword.get(opts, :planning_model)

    if is_function(model, 2), do: {:request_function, model}
  end
end
