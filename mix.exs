defmodule SpectreDirective.MixProject do
  use Mix.Project

  @version "0.3.0"
  @source_url "https://github.com/elchemista/spectre_directive"

  def project do
    [
      app: :spectre_directive,
      name: "SpectreDirective",
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      test_coverage: [summary: [threshold: 90]],
      dialyzer: [
        plt_add_apps: [:mix]
      ],
      docs: docs(),
      source_url: @source_url,
      homepage_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp description do
    "An embeddable, self-correcting mission and plan loop for Elixir agents"
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [
        "README.md",
        "docs/PUBLIC_API.md",
        "docs/GETTING_STARTED.md",
        "docs/SPECTRE_AGENT_INTEGRATION.md",
        "examples/EXAMPLES.md",
        "CHANGELOG.md",
        "ROADMAP.md",
        "CONTRIBUTING.md",
        "SECURITY.md",
        "RELEASING.md",
        "LICENSE"
      ],
      groups_for_extras: [
        "Start here": [
          "README.md",
          "docs/PUBLIC_API.md",
          "docs/GETTING_STARTED.md",
          "docs/SPECTRE_AGENT_INTEGRATION.md",
          "examples/EXAMPLES.md"
        ],
        Project: [
          "CHANGELOG.md",
          "ROADMAP.md",
          "CONTRIBUTING.md",
          "SECURITY.md",
          "RELEASING.md",
          "LICENSE"
        ]
      ],
      groups_for_modules: [
        "Public API": [
          Spectre.Directive,
          SpectreDirective,
          SpectreDirective.DSL
        ],
        "Mission model": [
          SpectreDirective.Context,
          SpectreDirective.Information,
          SpectreDirective.Mission,
          SpectreDirective.MissionBlueprint,
          SpectreDirective.Outcome,
          SpectreDirective.Plan,
          SpectreDirective.PlanPatch,
          SpectreDirective.Request,
          SpectreDirective.Step,
          SpectreDirective.Trace.Entry,
          SpectreDirective.WorkingContext
        ],
        "Host contracts": [
          Spectre.Directive.Handler,
          Spectre.Directive.Invoker,
          Spectre.Directive.Presenter,
          Spectre.Directive.Policy,
          Spectre.Directive.Reasoner,
          Spectre.Directive.RequestHandler,
          Spectre.Directive.Snapshot,
          Spectre.Directive.Store,
          SpectreDirective.AgentDecision,
          SpectreDirective.Invocation,
          SpectreDirective.Invocation.Result,
          SpectreDirective.Invoker,
          SpectreDirective.Policy,
          SpectreDirective.Reasoner,
          SpectreDirective.RequestHandler
        ],
        "Pure engine": [
          SpectreDirective.Loop.Engine,
          SpectreDirective.Loop.State,
          SpectreDirective.Protocol
        ],
        "Runtime and integrations": [
          SpectreDirective.Integration.GenServer,
          SpectreDirective.Integration.SpectreAgent,
          SpectreDirective.Pulse,
          SpectreDirective.Runtime.Supervisor
        ]
      ]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      spectre_dep()
    ]
  end

  defp spectre_dep do
    case System.get_env("SPECTRE_PATH") do
      path when is_binary(path) and path != "" ->
        {:spectre, path: Path.expand(path, __DIR__), override: true}

      _unset ->
        {:spectre, "~> 0.3.0"}
    end
  end
end
