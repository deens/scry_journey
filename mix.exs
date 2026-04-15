defmodule ScryJourney.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :scry_journey,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: false,
      deps: deps(),
      description: "Executable journey cards with checkpoint assertions for Elixir applications",
      package: package(),
      source_url: "https://github.com/deens/scry_journey"
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ScryJourney.Application, []}
    ]
  end

  defp deps do
    [
      {:jason, "~> 1.4"},
      scry_dep()
    ]
    |> Enum.reject(&is_nil/1)
  end

  # Optional dependency on Scry for remote execution transport.
  # Resolves via:
  #   1. SCRY_PATH env var (explicit override)
  #   2. Sibling `../scry` directory (workspace/ecosystem layout)
  #   3. Hex package (standalone installs)
  # Without Scry, journeys run locally via apply/3.
  defp scry_dep do
    cond do
      path = System.get_env("SCRY_PATH") ->
        {:scry, path: path, optional: true}

      File.dir?(Path.expand("../scry", __DIR__)) ->
        {:scry, path: "../scry", optional: true}

      true ->
        {:scry, "~> 0.4.0", optional: true}
    end
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/deens/scry_journey"}
    ]
  end
end
