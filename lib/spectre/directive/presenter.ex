defmodule Spectre.Directive.Presenter do
  @moduledoc """
  Optional presentation boundary for Spectre-facing Directive replies.

  The built-in presenter turns questions, confirmations, policy requests, and
  outcomes into conservative user-visible text. Applications can pass a
  presenter module or function when localization or richer wording is needed.
  The complete typed boundary remains available in result metadata.
  """

  alias SpectreDirective.Outcome
  alias SpectreDirective.Request

  @type boundary :: {:request, Request.t()} | {:outcome, Outcome.t()}
  @type target :: module() | {module(), keyword()} | (boundary(), keyword() -> term())

  @callback present(boundary(), keyword()) ::
              String.t() | {:ok, String.t()} | {:error, term()}

  @doc "Presents a boundary with the built-in conservative wording."
  @spec present(boundary(), keyword()) :: String.t()
  def present({:request, %Request{kind: :question, payload: payload}}, _opts) do
    stringify(Map.get(payload, :question, "Please provide the missing information."))
  end

  def present({:request, %Request{kind: :confirmation, payload: payload}}, _opts) do
    case Map.get(payload, :question) || Map.get(payload, :prompt) do
      nil -> "Please confirm the proposed #{Map.get(payload, :proposal_type, :change)}."
      prompt -> stringify(prompt)
    end
  end

  def present({:request, %Request{kind: :policy, payload: payload}}, _opts) do
    case Map.get(payload, :question) || Map.get(payload, :prompt) do
      nil -> "Approval is required to continue."
      prompt -> stringify(prompt)
    end
  end

  def present({:outcome, %Outcome{status: :completed, result: result}}, _opts)
      when is_binary(result) do
    if String.trim(result) == "", do: "Mission completed.", else: result
  end

  def present({:outcome, %Outcome{status: :completed}}, _opts), do: "Mission completed."

  def present({:outcome, %Outcome{status: :failed}}, _opts),
    do: "The mission could not be completed."

  def present({:outcome, %Outcome{status: :cancelled}}, _opts), do: "Mission cancelled."

  @doc "Calls a configured presenter target and normalizes its reply."
  @spec call(target() | nil, boundary(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def call(target, boundary, opts \\ [])

  def call(nil, boundary, opts), do: normalize(present(boundary, opts))

  def call(function, boundary, opts) when is_function(function, 2),
    do: invoke(:function, fn -> function.(boundary, opts) end)

  def call({module, target_opts}, boundary, opts)
      when is_atom(module) and is_list(target_opts) and is_list(opts) do
    if Keyword.keyword?(target_opts) and Keyword.keyword?(opts) do
      call(module, boundary, Keyword.merge(target_opts, opts))
    else
      {:error, :invalid_directive_presenter_options}
    end
  end

  def call(module, boundary, opts)
      when is_atom(module) and not is_nil(module) and is_list(opts) do
    if Code.ensure_loaded?(module) and function_exported?(module, :present, 2) do
      invoke(module, fn -> module.present(boundary, opts) end)
    else
      {:error, {:undefined_directive_presenter, module}}
    end
  end

  def call(target, _boundary, _opts), do: {:error, {:invalid_directive_presenter, shape(target)}}

  @spec normalize(term()) :: {:ok, String.t()} | {:error, term()}
  defp normalize({:ok, text}) when is_binary(text), do: {:ok, text}
  defp normalize(text) when is_binary(text), do: {:ok, text}
  defp normalize({:error, _reason} = error), do: error
  defp normalize(reply), do: {:error, {:invalid_directive_presenter_reply, shape(reply)}}

  @spec invoke(module() | :function, (-> term())) ::
          {:ok, String.t()} | {:error, term()}
  defp invoke(target, function) do
    function.() |> normalize()
  rescue
    exception -> {:error, {:directive_presenter_exception, target, exception.__struct__}}
  catch
    kind, reason -> {:error, {:directive_presenter_failure, target, kind, reason}}
  end

  @spec stringify(term()) :: String.t()
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: inspect(value, limit: 20, printable_limit: 200)

  @spec shape(term()) :: atom() | {:struct, module()}
  defp shape(value) when is_atom(value), do: :atom
  defp shape(value) when is_binary(value), do: :binary
  defp shape(value) when is_list(value), do: :list
  defp shape(%{__struct__: module}), do: {:struct, module}
  defp shape(value) when is_map(value), do: :map
  defp shape(value) when is_tuple(value), do: :tuple
  defp shape(value) when is_function(value), do: :function
  defp shape(_value), do: :other
end
