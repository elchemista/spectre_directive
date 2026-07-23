defmodule SpectreDirective.Integration do
  @moduledoc false

  alias SpectreDirective.Integration.SpectreAgent
  alias SpectreDirective.Integration.SpectreAgent.DecisionResolver

  @host_attribute :__spectre_directive_host__
  @options_attribute :__spectre_directive_options__
  @spectre_marker "__spectre_directive_reason__"

  @type host :: :standalone | :spectre_agent | :gen_server

  @doc false
  @spec register(module(), keyword()) :: host()
  def register(module, opts) when is_atom(module) and is_list(opts) do
    host = opts |> Keyword.get(:host, :auto) |> normalize_host(module)
    validate_host!(host, module)
    register_attributes(module, host, opts)
    install_unified_handler(module, host)
    register_host(module, host, opts)
    host
  end

  @doc false
  @spec before_compile(Macro.Env.t()) :: Macro.t()
  def before_compile(env) do
    host = Module.get_attribute(env.module, @host_attribute) || :standalone
    detect_late_host!(host, env.module)
    compile_host(env.module, host)
  end

  @doc false
  @spec marker() :: binary()
  def marker, do: @spectre_marker

  @doc false
  @spec handle(module(), host(), Spectre.Directive.Handler.message(), term()) :: term()
  def handle(owner, :spectre_agent, {:reason, context}, spectre_context),
    do: SpectreAgent.default_reason(owner, context, spectre_context)

  def handle(_owner, :spectre_agent, {:invocation, target}, _context),
    do: DecisionResolver.trusted_invocation(target)

  def handle(_owner, :gen_server, {event, mission_id, _payload}, state)
      when is_atom(event) and is_binary(mission_id),
      do: {:noreply, state}

  def handle(_owner, host, message, host_context),
    do: {:error, {:unsupported_directive_message, host, message, host_context}}

  @spec register_attributes(module(), host(), keyword()) :: :ok
  defp register_attributes(module, host, opts) do
    Module.register_attribute(module, @host_attribute, persist: false)
    Module.register_attribute(module, @options_attribute, persist: false)
    Module.put_attribute(module, @host_attribute, host)
    Module.put_attribute(module, @options_attribute, opts)
    :ok
  end

  @spec register_host(module(), host(), keyword()) :: :ok
  defp register_host(module, :spectre_agent, opts) do
    SpectreDirective.Integration.SpectreAgent.Compiler.register(module, opts)
  end

  defp register_host(module, :gen_server, opts) do
    SpectreDirective.Integration.GenServer.Compiler.register(module, opts)
  end

  defp register_host(_module, :standalone, _opts), do: :ok

  @spec compile_host(module(), host()) :: Macro.t()
  defp compile_host(module, :spectre_agent) do
    SpectreDirective.Integration.SpectreAgent.Compiler.before_compile(module)
  end

  defp compile_host(module, :gen_server) do
    SpectreDirective.Integration.GenServer.Compiler.before_compile(module)
  end

  defp compile_host(_module, :standalone) do
    quote do
      @doc false
      @spec __spectre_directive_host__() :: :standalone
      def __spectre_directive_host__, do: :standalone
    end
  end

  @spec normalize_host(term(), module()) :: host()
  defp normalize_host(:auto, module) do
    cond do
      spectre_agent?(module) -> :spectre_agent
      gen_server?(module) -> :gen_server
      true -> :standalone
    end
  end

  defp normalize_host(host, _module) when host in [:standalone, :spectre_agent, :gen_server],
    do: host

  defp normalize_host(:spectre, _module), do: :spectre_agent
  defp normalize_host(:genserver, _module), do: :gen_server

  defp normalize_host(host, _module) do
    raise ArgumentError,
          "invalid Spectre.Directive host #{inspect(host)}; expected :auto, :standalone, " <>
            ":spectre_agent, or :gen_server"
  end

  @spec spectre_agent?(module()) :: boolean()
  defp spectre_agent?(module) do
    Module.has_attribute?(module, :spectre_rules) and
      Module.has_attribute?(module, :spectre_config)
  end

  @spec gen_server?(module()) :: boolean()
  defp gen_server?(module) do
    module
    |> Module.get_attribute(:behaviour)
    |> List.wrap()
    |> Enum.member?(GenServer)
  end

  @spec validate_host!(host(), module()) :: :ok | no_return()
  defp validate_host!(:spectre_agent, module) do
    if spectre_agent?(module) do
      :ok
    else
      raise ArgumentError,
            "host :spectre_agent requires use Spectre.Agent before use Spectre.Directive"
    end
  end

  defp validate_host!(:gen_server, module) do
    if gen_server?(module) do
      :ok
    else
      raise ArgumentError,
            "host :gen_server requires use GenServer before use Spectre.Directive"
    end
  end

  defp validate_host!(:standalone, _module), do: :ok

  @spec detect_late_host!(host(), module()) :: :ok | no_return()
  defp detect_late_host!(:standalone, module) do
    cond do
      spectre_agent?(module) ->
        raise ArgumentError, "use Spectre.Agent must appear before use Spectre.Directive"

      gen_server?(module) ->
        raise ArgumentError, "use GenServer must appear before use Spectre.Directive"

      true ->
        :ok
    end
  end

  defp detect_late_host!(_host, _module), do: :ok

  @spec install_unified_handler(module(), host()) :: :ok
  defp install_unified_handler(_module, :standalone), do: :ok

  defp install_unified_handler(module, host) do
    if not Module.defines?(module, {:handle_directive, 2}) do
      Code.eval_quoted(
        quote do
          @behaviour Spectre.Directive.Handler

          @doc "Handles a reasoning boundary, invocation target, or live mission event."
          @spec handle_directive(Spectre.Directive.Handler.message(), term()) :: term()
          @impl Spectre.Directive.Handler
          def handle_directive(message, host_context) do
            SpectreDirective.Integration.handle(
              __MODULE__,
              unquote(host),
              message,
              host_context
            )
          end

          defoverridable handle_directive: 2
        end,
        [],
        %{__ENV__ | module: module, function: nil, context: nil}
      )
    end

    :ok
  end
end
