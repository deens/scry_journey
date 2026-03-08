defmodule ScryJourney do
  @moduledoc """
  Executable journey verification for Elixir applications.

  Supports two formats:
  - **v1 Journey Cards** (`.journey.json`) — Single function call + checkpoint assertions
  - **v2 Journey Scripts** (`.journey.exs`) — Multi-step scripts with context threading,
    async observation, and teardown guarantees

  ## Quick Start (v1 — JSON cards)

      {:ok, report} = ScryJourney.verify("journeys/health_check.journey.json")
      report.pass  # => true or false

  ## Quick Start (v2 — Elixir scripts)

      {:ok, report} = ScryJourney.verify_script("journeys/match_lifecycle.journey.exs")
      report.pass        # => true or false
      report.step_counts # => %{pass: 3, fail: 0, skipped: 0, error: 0}

  ## Suite (runs both formats)

      report = ScryJourney.run_suite("journeys/")
      report.summary  # => %{total: 6, passed: 6, failed: 0, errors: 0}
  """

  # -- v1: Journey Cards (.journey.json) --

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

  # -- v2: Journey Scripts (.journey.exs) --

  @doc "Load a journey script from an .exs file."
  @spec load_script(String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate load_script(path), to: ScryJourney.Script, as: :load

  @doc "Run a loaded journey script and return a report."
  @spec run_script(map(), keyword()) :: map()
  defdelegate run_script(script, opts \\ []), to: ScryJourney.RunnerV2, as: :run

  @doc "Load and run a journey script in one call."
  @spec verify_script(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify_script(path, opts \\ []) do
    with {:ok, script} <- load_script(path) do
      {:ok, run_script(script, opts)}
    end
  end

  @doc "Build a script from inline arguments and run it."
  @spec run_inline(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_inline(args, opts \\ []) do
    with {:ok, script} <- ScryJourney.Script.from_inline(args) do
      {:ok, run_script(script, opts)}
    end
  end

  # -- Suite (both formats) --

  @doc """
  Run all journeys in a directory and return an aggregate report.

  Discovers both `.journey.json` and `.journey.exs` files, runs each one,
  and produces a summary with overall pass/fail status.

      report = ScryJourney.run_suite("journeys/")
      report.pass     # => true if all journeys pass
      report.summary  # => %{total: 4, passed: 4, failed: 0, errors: 0}
  """
  @spec run_suite(String.t() | [String.t()], keyword()) :: map()
  defdelegate run_suite(dir_or_paths, opts \\ []), to: ScryJourney.Suite, as: :run
end
