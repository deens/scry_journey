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

  @doc """
  Load and run a journey script in one call.

  ## Options

  - `:emitter` — event emission function (see `ScryJourney.EventEmitter`)
  - `:record` — path to save recording ETF file (auto-creates emitter)
  """
  @spec verify_script(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify_script(path, opts \\ []) do
    with {:ok, script} <- load_script(path) do
      opts = opts |> maybe_add_prism_emitter() |> maybe_add_recording_emitter()
      report = run_script(script, opts)
      maybe_save_recording(opts)
      {:ok, report}
    end
  end

  @doc "Build a script from inline arguments and run it."
  @spec run_inline(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_inline(args, opts \\ []) do
    with {:ok, script} <- ScryJourney.Script.from_inline(args) do
      opts = opts |> maybe_add_prism_emitter() |> maybe_add_recording_emitter()
      report = run_script(script, opts)
      maybe_save_recording(opts)
      {:ok, report}
    end
  end

  defp maybe_add_prism_emitter(opts) do
    if Keyword.has_key?(opts, :emitter) do
      opts
    else
      if ScryJourney.EventEmitter.prism_available?() do
        Keyword.put(opts, :emitter, ScryJourney.EventEmitter.prism())
      else
        opts
      end
    end
  end

  defp maybe_add_recording_emitter(opts) do
    case Keyword.get(opts, :record) do
      nil ->
        opts

      path when is_binary(path) ->
        {rec_emitter, agent} = ScryJourney.Recording.emitter()
        existing = Keyword.get(opts, :emitter)

        emitter =
          if existing do
            ScryJourney.EventEmitter.combine([existing, rec_emitter])
          else
            rec_emitter
          end

        opts
        |> Keyword.put(:emitter, emitter)
        |> Keyword.put(:_recording_agent, agent)
        |> Keyword.put(:_recording_path, path)
    end
  end

  defp maybe_save_recording(opts) do
    case {Keyword.get(opts, :_recording_agent), Keyword.get(opts, :_recording_path)} do
      {agent, path} when is_pid(agent) and is_binary(path) ->
        ScryJourney.Recording.save(agent, path)

      _ ->
        :ok
    end
  end

  # -- Mode (continuous execution) --

  @doc """
  Start a journey mode watcher that runs a script on a schedule.

  Returns `{:ok, pid}` for the mode GenServer.

  ## Options

  - `:interval` — ms between runs (default 30_000)
  - `:emitter` — event emitter (auto-wires Prism if available)
  - `:props` — prop overrides
  - `:props_mode` — `:fixed`, `:random`, or `:rotate`
  - `:name` — GenServer name for the watcher

  ## Example

      {:ok, watcher} = ScryJourney.watch("journeys/health.journey.exs", interval: 60_000)
      ScryJourney.Mode.status(watcher)
      ScryJourney.Mode.stop(watcher)
  """
  @spec watch(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def watch(path, opts \\ []) do
    with {:ok, script} <- load_script(path) do
      opts =
        opts
        |> Keyword.put_new_lazy(:emitter, fn ->
          if ScryJourney.EventEmitter.prism_available?() do
            ScryJourney.EventEmitter.prism()
          else
            ScryJourney.EventEmitter.noop()
          end
        end)
        |> Keyword.put(:script, script)

      ScryJourney.Mode.start_link(opts)
    end
  end

  @doc """
  Run a journey script with all prop combinations and return results.

  Useful for testing a journey against its full parameter space.
  Returns a list of `{props, report}` tuples.
  """
  @spec run_matrix(map(), keyword()) :: [{map(), map()}]
  def run_matrix(script, opts \\ []) do
    combos = ScryJourney.Props.expand(script)
    opts = maybe_add_prism_emitter(opts)

    Enum.map(combos, fn props ->
      report = run_script(script, Keyword.put(opts, :props, props))
      {props, report}
    end)
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

  # -- Watch Suite (continuous mode for all journeys) --

  @doc """
  Start watchers for all journey scripts in a directory.

  Returns `{:ok, supervisor_pid}` for a ModeSupervisor that manages
  individual Mode watchers for each `.journey.exs` file found.

  ## Options

  - `:interval` — ms between runs (default 30_000)
  - `:emitter` — shared event emitter (auto-wires Prism if available)
  - `:props_mode` — `:fixed`, `:random`, or `:rotate` (default `:fixed`)
  - `:name` — GenServer name for the supervisor

  ## Example

      {:ok, sup} = ScryJourney.watch_suite("journeys/", interval: 60_000)
      ScryJourney.ModeSupervisor.health(sup)
      ScryJourney.ModeSupervisor.stop(sup)
  """
  @spec watch_suite(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def watch_suite(directory, opts \\ []) do
    opts = Keyword.put(opts, :directory, directory)
    ScryJourney.ModeSupervisor.start_link(opts)
  end
end
