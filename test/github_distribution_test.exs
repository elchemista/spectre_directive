defmodule SpectreDirective.GitHubDistributionTest do
  use ExUnit.Case, async: true

  test "Spectre is a direct Hex dependency in this GitHub-only project" do
    config = Mix.Project.config()
    dependency = Enum.find(Keyword.fetch!(config, :deps), &(elem(&1, 0) == :spectre))

    assert dependency == {:spectre, "~> 0.3.0"}
    refute Keyword.has_key?(config, :package)
  end
end
