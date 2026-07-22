defmodule SpectreDirective.Integration.GenServer.Compiler do
  @moduledoc false

  @doc false
  @spec register(module(), keyword()) :: :ok
  def register(module, opts) do
    install? = Keyword.get(opts, :gen_server_handler, true)

    if install? and not Module.defines?(module, {:handle_info, 2}) do
      install_handle_info(module)
    end

    :ok
  end

  @doc false
  @spec before_compile(module()) :: Macro.t()
  def before_compile(module) do
    definitions = [
      host_introspection(),
      maybe_start_directive(module),
      maybe_directive_info_dispatch(module),
      maybe_native_handle_info(module)
    ]

    quote do
      (unquote_splicing(definitions))
    end
  end

  @spec install_handle_info(module()) :: :ok
  defp install_handle_info(module) do
    # This clause must exist before GenServer's own before_compile hook decides
    # whether to emit its fallback. Defining only the Directive pattern keeps
    # later application handle_info clauses reachable.
    Code.eval_quoted(
      quote do
        @doc false
        @spec handle_info(term(), term()) :: term()
        def handle_info(
              {:spectre_directive, _mission_id, _event, _payload} = message,
              state
            ) do
          SpectreDirective.Integration.GenServer.handle_info(__MODULE__, message, state)
        end
      end,
      [],
      %{__ENV__ | module: module, function: nil, context: nil}
    )

    :ok
  end

  @spec maybe_start_directive(module()) :: Macro.t()
  defp maybe_start_directive(module) do
    if Module.defines?(module, {:start_directive, 2}) or
         Module.defines?(module, {:start_directive, 3}) do
      empty_quote()
    else
      quote do
        @doc "Starts one authored directive and subscribes the given GenServer."
        @spec start_directive(GenServer.server(), binary() | atom() | nil) ::
                {:ok, pid()} | {:error, term()}
        def start_directive(server, name), do: start_directive(server, name, [])

        @doc "Starts one authored directive with per-run runtime options."
        @spec start_directive(GenServer.server(), binary() | atom() | nil, keyword()) ::
                {:ok, pid()} | {:error, term()}
        def start_directive(server, name, opts) do
          SpectreDirective.Integration.GenServer.start(__MODULE__, server, name, opts)
        end
      end
    end
  end

  @spec maybe_directive_info_dispatch(module()) :: Macro.t()
  defp maybe_directive_info_dispatch(module) do
    if Module.defines?(module, {:directive_handle_info, 2}) do
      empty_quote()
    else
      quote do
        @doc "Dispatches a Directive runtime message to handle_directive/2."
        @spec directive_handle_info(term(), term()) :: term()
        def directive_handle_info(message, state) do
          SpectreDirective.Integration.GenServer.handle_info(__MODULE__, message, state)
        end
      end
    end
  end

  @spec maybe_native_handle_info(module()) :: Macro.t()
  defp maybe_native_handle_info(module) do
    if Module.defines?(module, {:handle_info, 2}) do
      empty_quote()
    else
      quote do
        @doc false
        @spec handle_info(term(), term()) :: term()
        @impl GenServer
        def handle_info(
              {:spectre_directive, _mission_id, _event, _payload} = message,
              state
            ) do
          directive_handle_info(message, state)
        end

        def handle_info(_message, state), do: {:noreply, state}
      end
    end
  end

  @spec host_introspection() :: Macro.t()
  defp host_introspection do
    quote do
      @doc false
      @spec __spectre_directive_host__() :: :gen_server
      def __spectre_directive_host__, do: :gen_server
    end
  end

  @spec empty_quote() :: Macro.t()
  defp empty_quote, do: quote(do: nil)
end
