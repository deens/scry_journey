defmodule ScryJourney do
  @moduledoc """
  Executable journey cards with checkpoint assertions for Elixir applications.

  ScryJourney lets you define feature contracts as JSON journey cards,
  execute them against a running application, and verify results through
  checkpoint assertions.

  ## Quick Start

      # Load and run a journey card
      {:ok, card} = ScryJourney.load("journeys/user_registration.journey.json")
      report = ScryJourney.run(card)
      report.pass  # => true or false

      # Or load + run in one call
      {:ok, report} = ScryJourney.verify("journeys/user_registration.journey.json")

  ## Journey Card Format

  Journey cards are JSON files with:
  - An execution spec (module + function to call)
  - Checkpoint assertions (path-based checks on the result)

  See `ScryJourney.Card` for the full format specification.
  """

  @doc "Load a journey card from a JSON file."
  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate load(path), to: ScryJourney.Card

  @doc "Run a loaded journey card and return a report."
  @spec run(map(), keyword()) :: map()
  defdelegate run(card, opts \\ []), to: ScryJourney.Runner

  @doc "Load and run a journey card in one call."
  @spec verify(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(path, opts \\ []) do
    with {:ok, card} <- load(path) do
      {:ok, run(card, opts)}
    end
  end
end
