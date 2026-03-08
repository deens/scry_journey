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

  ## Journey Card Format

  Journey cards are JSON files with:
  - An execution spec (module + function to call)
  - Checkpoint assertions (path-based checks on the result)

  See `ScryJourney.Card` for the full format specification.
  """

  @doc "Load a journey card from a JSON file."
  defdelegate load(path), to: ScryJourney.Card

  @doc "Run a loaded journey card and return a report."
  defdelegate run(card, opts \\ []), to: ScryJourney.Runner

  @doc "Load and run a journey card in one call."
  def verify(path, opts \\ []) do
    with {:ok, card} <- load(path) do
      {:ok, run(card, opts)}
    end
  end
end
