defmodule Spectre.Directive.StackCompiler do
  @moduledoc false

  alias Spectre.Stack.DSL

  @spec compile(keyword(), Macro.t() | nil, Macro.Env.t()) ::
          {:ok, map()} | {:error, term()}
  def compile(opts, block, caller) do
    declarations =
      DSL.compile!(block, caller,
        store: 1,
        clock: 1,
        resident_runs: 1
      )

    compile_declarations(declarations, default_config(opts))
  end

  @spec compile_declarations([{atom(), [term()]}], map()) :: {:ok, map()} | {:error, term()}
  defp compile_declarations(declarations, config) do
    Enum.reduce_while(declarations, {:ok, config}, fn declaration, {:ok, current} ->
      case compile_declaration(declaration, current) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec compile_declaration({atom(), [term()]}, map()) :: {:ok, map()} | {:error, term()}
  defp compile_declaration({:store, [store]}, %{store: nil} = config) do
    if valid_module?(store),
      do: {:ok, %{config | store: store}},
      else: {:error, {:invalid_store, store}}
  end

  defp compile_declaration({:store, [_store]}, _config),
    do: {:error, {:duplicate_declaration, :store}}

  defp compile_declaration({:clock, [clock]}, %{clock: nil} = config) do
    if valid_module?(clock),
      do: {:ok, %{config | clock: clock}},
      else: {:error, {:invalid_clock, clock}}
  end

  defp compile_declaration({:clock, [_clock]}, _config),
    do: {:error, {:duplicate_declaration, :clock}}

  defp compile_declaration(
         {:resident_runs, [resident_runs]},
         %{resident_runs: nil} = config
       )
       when is_integer(resident_runs) and resident_runs > 0 do
    {:ok, %{config | resident_runs: resident_runs}}
  end

  defp compile_declaration({:resident_runs, [resident_runs]}, %{resident_runs: nil}),
    do: {:error, {:invalid_resident_runs, resident_runs}}

  defp compile_declaration({:resident_runs, [_resident_runs]}, _config),
    do: {:error, {:duplicate_declaration, :resident_runs}}

  @spec default_config(keyword()) :: map()
  defp default_config(opts) do
    %{
      options: opts,
      store: nil,
      clock: nil,
      resident_runs: nil
    }
  end

  @spec valid_module?(term()) :: boolean()
  defp valid_module?(module), do: is_atom(module) and not is_nil(module)
end
