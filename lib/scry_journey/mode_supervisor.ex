defmodule ScryJourney.ModeSupervisor do
  @moduledoc """
  Supervises multiple Mode watchers from a directory of journey scripts.

  Discovers `.journey.exs` files, starts a Mode watcher for each one,
  and provides aggregate health status. Turns a directory of journeys
  into a living health dashboard.

  ## Usage

      # Watch all journeys in a directory
      {:ok, sup} = ScryJourney.ModeSupervisor.start_link(
        directory: "journeys/",
        interval: 30_000
      )

      # Get health status for all watchers
      ScryJourney.ModeSupervisor.health(sup)
      # => %{total: 4, healthy: 3, failing: 1, watchers: [...]}

      # Add a new journey at runtime
      ScryJourney.ModeSupervisor.add(sup, "journeys/new.journey.exs")

      # Remove a watcher
      ScryJourney.ModeSupervisor.remove(sup, "match_matrix")

  ## Architecture

  Uses a GenServer wrapping a DynamicSupervisor to track watcher
  metadata (journey_id → pid mapping, config). Each watcher is a
  `ScryJourney.Mode` GenServer supervised under the DynamicSupervisor.
  """

  use GenServer

  alias ScryJourney.{Mode, Suite}

  require Logger

  # ──────────────────────────────────────────────
  # Public API
  # ──────────────────────────────────────────────

  @doc """
  Start a mode supervisor that watches all journeys in a directory.

  ## Options

  - `:directory` — path to journey directory (required unless `:scripts` given)
  - `:scripts` — list of `{id, script_map}` tuples to watch directly
  - `:interval` — ms between runs for all watchers (default 30_000)
  - `:emitter` — shared event emitter
  - `:props_mode` — `:fixed`, `:random`, or `:rotate` (default `:fixed`)
  - `:name` — GenServer name (optional)
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Get aggregate health status for all watchers."
  @spec health(GenServer.server()) :: map()
  def health(server) do
    GenServer.call(server, :health)
  end

  @doc "List all active watchers with their status."
  @spec list(GenServer.server()) :: [map()]
  def list(server) do
    GenServer.call(server, :list)
  end

  @doc "Add a journey script file to the supervisor."
  @spec add(GenServer.server(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def add(server, path, opts \\ []) do
    GenServer.call(server, {:add, path, opts})
  end

  @doc "Add an inline script map to the supervisor."
  @spec add_script(GenServer.server(), map(), keyword()) :: {:ok, pid()} | {:error, term()}
  def add_script(server, script, opts \\ []) do
    GenServer.call(server, {:add_script, script, opts})
  end

  @doc "Remove a watcher by journey ID."
  @spec remove(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def remove(server, journey_id) do
    GenServer.call(server, {:remove, journey_id})
  end

  @doc "Trigger immediate runs for all watchers."
  @spec run_all(GenServer.server()) :: :ok
  def run_all(server) do
    GenServer.cast(server, :run_all)
  end

  @doc "Pause all watchers."
  @spec pause_all(GenServer.server()) :: :ok
  def pause_all(server) do
    GenServer.cast(server, :pause_all)
  end

  @doc "Resume all watchers."
  @spec resume_all(GenServer.server()) :: :ok
  def resume_all(server) do
    GenServer.cast(server, :resume_all)
  end

  @doc "Stop the supervisor and all watchers."
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  # ──────────────────────────────────────────────
  # GenServer callbacks
  # ──────────────────────────────────────────────

  @impl true
  def init(opts) do
    {:ok, sup_pid} = DynamicSupervisor.start_link(strategy: :one_for_one)

    state = %{
      sup_pid: sup_pid,
      watchers: %{},
      default_interval: Keyword.get(opts, :interval, 30_000),
      default_emitter: Keyword.get(opts, :emitter),
      default_props_mode: Keyword.get(opts, :props_mode, :fixed)
    }

    state =
      cond do
        Keyword.has_key?(opts, :directory) ->
          start_from_directory(state, Keyword.fetch!(opts, :directory), opts)

        Keyword.has_key?(opts, :scripts) ->
          start_from_scripts(state, Keyword.fetch!(opts, :scripts), opts)

        true ->
          state
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:health, _from, state) do
    statuses = collect_statuses(state)

    healthy = Enum.count(statuses, &(&1.last_status == "PASS"))
    failing = Enum.count(statuses, &(&1.last_status == "FAIL"))
    pending = Enum.count(statuses, &is_nil(&1.last_status))

    health = %{
      total: map_size(state.watchers),
      healthy: healthy,
      failing: failing,
      pending: pending,
      all_healthy: failing == 0 and pending == 0,
      watchers: statuses
    }

    {:reply, health, state}
  end

  def handle_call(:list, _from, state) do
    {:reply, collect_statuses(state), state}
  end

  def handle_call({:add, path, opts}, _from, state) do
    case ScryJourney.load_script(path) do
      {:ok, script} ->
        case start_watcher(state, script, opts) do
          {:ok, pid, state} -> {:reply, {:ok, pid}, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:add_script, script, opts}, _from, state) do
    case start_watcher(state, script, opts) do
      {:ok, pid, state} -> {:reply, {:ok, pid}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:remove, journey_id}, _from, state) do
    case Map.get(state.watchers, journey_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{pid: pid} ->
        DynamicSupervisor.terminate_child(state.sup_pid, pid)
        {:reply, :ok, %{state | watchers: Map.delete(state.watchers, journey_id)}}
    end
  end

  @impl true
  def handle_cast(:run_all, state) do
    for {_id, %{pid: pid}} <- state.watchers, Process.alive?(pid) do
      Mode.run_now(pid)
    end

    {:noreply, state}
  end

  def handle_cast(:pause_all, state) do
    for {_id, %{pid: pid}} <- state.watchers, Process.alive?(pid) do
      Mode.pause(pid)
    end

    {:noreply, state}
  end

  def handle_cast(:resume_all, state) do
    for {_id, %{pid: pid}} <- state.watchers, Process.alive?(pid) do
      Mode.resume(pid)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case find_watcher_by_pid(state.watchers, pid) do
      {journey_id, _info} ->
        Logger.warning("[ModeSupervisor] Watcher #{journey_id} exited: #{inspect(reason)}")
        {:noreply, %{state | watchers: Map.delete(state.watchers, journey_id)}}

      nil ->
        {:noreply, state}
    end
  end

  # ──────────────────────────────────────────────
  # Startup helpers
  # ──────────────────────────────────────────────

  defp start_from_directory(state, directory, _opts) do
    paths = Suite.discover(directory) |> Enum.filter(&String.ends_with?(&1, ".journey.exs"))

    Enum.reduce(paths, state, fn path, acc ->
      case ScryJourney.load_script(path) do
        {:ok, script} ->
          case start_watcher(acc, script, []) do
            {:ok, _pid, new_state} ->
              new_state

            {:error, reason} ->
              Logger.warning(
                "[ModeSupervisor] Failed to start watcher for #{path}: #{inspect(reason)}"
              )

              acc
          end

        {:error, reason} ->
          Logger.warning("[ModeSupervisor] Failed to load #{path}: #{inspect(reason)}")
          acc
      end
    end)
  end

  defp start_from_scripts(state, scripts, _opts) do
    Enum.reduce(scripts, state, fn {_id, script}, acc ->
      case start_watcher(acc, script, []) do
        {:ok, _pid, new_state} ->
          new_state

        {:error, reason} ->
          Logger.warning("[ModeSupervisor] Failed to start watcher: #{inspect(reason)}")
          acc
      end
    end)
  end

  defp start_watcher(state, script, opts) do
    journey_id = script[:id] || "unknown_#{:erlang.unique_integer([:positive])}"

    if Map.has_key?(state.watchers, journey_id) do
      {:error, {:already_watching, journey_id}}
    else
      emitter = Keyword.get(opts, :emitter, state.default_emitter) || resolve_emitter()
      interval = Keyword.get(opts, :interval, state.default_interval)
      props_mode = Keyword.get(opts, :props_mode, state.default_props_mode)

      mode_opts = [
        script: script,
        interval: interval,
        emitter: emitter,
        props_mode: props_mode
      ]

      case DynamicSupervisor.start_child(state.sup_pid, {Mode, mode_opts}) do
        {:ok, pid} ->
          ref = Process.monitor(pid)

          watcher_info = %{
            pid: pid,
            ref: ref,
            journey_id: journey_id,
            started_at: System.monotonic_time(:millisecond)
          }

          {:ok, pid, %{state | watchers: Map.put(state.watchers, journey_id, watcher_info)}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp resolve_emitter do
    if ScryJourney.EventEmitter.prism_available?() do
      ScryJourney.EventEmitter.prism()
    else
      ScryJourney.EventEmitter.noop()
    end
  end

  # ──────────────────────────────────────────────
  # Query helpers
  # ──────────────────────────────────────────────

  defp collect_statuses(state) do
    Enum.map(state.watchers, fn {journey_id, %{pid: pid}} ->
      if Process.alive?(pid) do
        Mode.status(pid)
      else
        %{journey_id: journey_id, state: :dead, runs: 0, last_status: nil}
      end
    end)
  end

  defp find_watcher_by_pid(watchers, pid) do
    Enum.find(watchers, fn {_id, info} -> info.pid == pid end)
  end
end
