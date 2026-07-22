defmodule SpectreDirective.MixProject do
  use Mix.Project

  @version "0.1.0"
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
      package: package(),
      test_coverage: [summary: [threshold: 90]],
      dialyzer: [
        plt_add_apps: [:mix]
      ],
      docs: [
        main: "readme",
        extras: ["README.md", "LICENSE"]
      ],
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

  defp package do
    [
      name: "spectre_directive",
      maintainers: ["elchemista"],
      files: ~w(lib mix.exs README.md LICENSE),
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:spectre, github: "elchemista/spectre", only: :test}
    ]
  end
end
