defmodule ScryJourney.Mode do
  @moduledoc """
  Continuous journey execution mode.

  Runs journey scripts on a schedule, compares runs, detects regressions,
  and feeds continuous status to Prism. Turns journeys from one-shot tests
  into living health monitors.

  ## Usage

      # Watch a single script
      {:ok, pid} = ScryJourney.Mode.start_link(
        script: ScryJourney.load_script!("journeys/match.journey.exs"),
        interval: 30_000,
        emitter: ScryJourney.EventEmitter.prism()
      )

      # Check status
      ScryJourney.Mode.status(pid)
      # => %{state: :watching, runs: 5, last_status: "PASS", regressions: 0}

      # Stop
      ScryJourney.Mode.stop(pid)

  ## Events

  Mode emits additional events via the emitter:
  - `:mode_tick` — each run completes (includes run count, status)
  - `:mode_regression` — status changed from pass to fail
  - `:mode_recovered` — status changed from fail to pass
  """

  use GenServer

  alias ScryJourney.{EventEmitter, RunnerV2, Props}

  require Logger

  @default_interval 30_000
  @min_interval 5_000

  # ──────────────────────────────────────────────
  # Public API
  # ──────────────────────────────────────────────

  @doc """
  Start a mode watcher for a journey script.

  ## Options

  - `:script` — the script map (required)
  - `:interval` — ms between runs (default 30_000, min 5_000)
  - `:emitter` — event emitter function
  - `:props` — prop overrides for each run
  - `:props_mode` — `:fixed` (default), `:random`, or `:rotate`
  - `:name` — GenServer name (optional)
  - `:run_immediately` — run first journey immediately (default true)
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Get the current status of the mode watcher."
  @spec status(GenServer.server()) :: map()
  def status(server) do
    GenServer.call(server, :status)
  end

  @doc "Get the last run report."
  @spec last_report(GenServer.server()) :: map() | nil
  def last_report(server) do
    GenServer.call(server, :last_report)
  end

  @doc "Get the run history (last N reports)."
  @spec history(GenServer.server(), non_neg_integer()) :: [map()]
  def history(server, limit \\ 10) do
    GenServer.call(server, {:history, limit})
  end

  @doc "Trigger an immediate run."
  @spec run_now(GenServer.server()) :: :ok
  def run_now(server) do
    GenServer.cast(server, :run_now)
  end

  @doc "Pause the watcher (stops scheduled runs)."
  @spec pause(GenServer.server()) :: :ok
  def pause(server) do
    GenServer.cast(server, :pause)
  end

  @doc "Resume a paused watcher."
  @spec resume(GenServer.server()) :: :ok
  def resume(server) do
    GenServer.cast(server, :resume)
  end

  @doc "Stop the mode watcher."
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  # ──────────────────────────────────────────────
  # GenServer callbacks
  # ──────────────────────────────────────────────

  @impl true
  def init(opts) do
    script = Keyword.fetch!(opts, :script)
    interval = max(Keyword.get(opts, :interval, @default_interval), @min_interval)
    emitter = Keyword.get(opts, :emitter, ScryJourney.EventEmitter.noop())
    props = Keyword.get(opts, :props, %{})
    props_mode = Keyword.get(opts, :props_mode, :fixed)
    run_immediately = Keyword.get(opts, :run_immediately, true)

    state = %{
      script: script,
      interval: interval,
      emitter: emitter,
      props: props,
      props_mode: props_mode,
      prop_rotation: nil,
      state: :watching,
      runs: 0,
      passes: 0,
      failures: 0,
      regressions: 0,
      recoveries: 0,
      last_report: nil,
      last_status: nil,
      history: [],
      max_history: 50,
      started_at: System.monotonic_time(:millisecond),
      timer_ref: nil
    }

    state =
      if props_mode == :rotate do
        combos = Props.expand(script)
        %{state | prop_rotation: combos}
      else
        state
      end

    # Tell Prism this journey is now continuously watched
    emitter.(
      :mode_started,
      EventEmitter.mode_started(script[:id] || "unknown", script, opts)
    )

    state =
      if run_immediately do
        send(self(), :tick)
        state
      else
        schedule_next(state)
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      state: state.state,
      journey_id: state.script[:id],
      interval_ms: state.interval,
      runs: state.runs,
      passes: state.passes,
      failures: state.failures,
      regressions: state.regressions,
      recoveries: state.recoveries,
      last_status: state.last_status,
      uptime_ms: System.monotonic_time(:millisecond) - state.started_at
    }

    {:reply, status, state}
  end

  def handle_call(:last_report, _from, state) do
    {:reply, state.last_report, state}
  end

  def handle_call({:history, limit}, _from, state) do
    {:reply, Enum.take(state.history, limit), state}
  end

  @impl true
  def handle_cast(:run_now, state) do
    state = cancel_timer(state)
    send(self(), :tick)
    {:noreply, state}
  end

  def handle_cast(:pause, state) do
    state = cancel_timer(state)
    {:noreply, %{state | state: :paused}}
  end

  def handle_cast(:resume, state) do
    state = %{state | state: :watching}
    send(self(), :tick)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, %{state: :paused} = state) do
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    state = execute_run(state)
    state = schedule_next(state)
    {:noreply, state}
  end

  # ──────────────────────────────────────────────
  # Execution
  # ──────────────────────────────────────────────

  defp execute_run(state) do
    props = resolve_run_props(state)
    run_opts = [emitter: state.emitter, props: props]

    report = RunnerV2.run(state.script, run_opts)
    run_number = state.runs + 1

    # Detect status transitions
    prev_status = state.last_status
    new_status = if report.pass, do: "PASS", else: "FAIL"

    {regressions, recoveries} =
      detect_transitions(prev_status, new_status, state.regressions, state.recoveries)

    # Emit mode events (pass state for enriched stats)
    emit_mode_events(
      state.emitter,
      state.script,
      report,
      run_number,
      prev_status,
      new_status,
      state
    )

    # Update history
    history_entry = %{
      run: run_number,
      status: new_status,
      duration_ms: report.duration_ms,
      props: props,
      at_ms: System.monotonic_time(:millisecond)
    }

    history = [history_entry | state.history] |> Enum.take(state.max_history)

    %{
      state
      | runs: run_number,
        passes: state.passes + if(report.pass, do: 1, else: 0),
        failures: state.failures + if(report.pass, do: 0, else: 1),
        regressions: regressions,
        recoveries: recoveries,
        last_report: report,
        last_status: new_status,
        history: history
    }
  end

  defp resolve_run_props(%{props_mode: :fixed, props: props}), do: props

  defp resolve_run_props(%{props_mode: :random, script: script}) do
    Props.random(script)
  end

  defp resolve_run_props(%{props_mode: :rotate, prop_rotation: combos, runs: runs}) do
    index = rem(runs, length(combos))
    Enum.at(combos, index)
  end

  defp detect_transitions(nil, _new, regressions, recoveries) do
    {regressions, recoveries}
  end

  defp detect_transitions("PASS", "FAIL", regressions, recoveries) do
    {regressions + 1, recoveries}
  end

  defp detect_transitions("FAIL", "PASS", regressions, recoveries) do
    {regressions, recoveries + 1}
  end

  defp detect_transitions(_, _, regressions, recoveries) do
    {regressions, recoveries}
  end

  defp emit_mode_events(emit, script, report, run_number, prev_status, new_status, state) do
    journey_id = script[:id] || "unknown"

    run_stats = %{
      run: run_number,
      status: new_status,
      passes: state.passes + if(report.pass, do: 1, else: 0),
      failures: state.failures + if(report.pass, do: 0, else: 1),
      regressions: state.regressions,
      recoveries: state.recoveries,
      props: state.props
    }

    # Always emit tick with enriched stats
    emit.(:mode_tick, EventEmitter.mode_tick(journey_id, report, run_stats))

    # Emit transitions
    case {prev_status, new_status} do
      {"PASS", "FAIL"} ->
        emit.(
          :mode_regression,
          EventEmitter.mode_regression(
            journey_id,
            run_number,
            "Regression detected: #{journey_id} went from PASS to FAIL"
          )
        )

      {"FAIL", "PASS"} ->
        emit.(
          :mode_recovered,
          EventEmitter.mode_recovered(
            journey_id,
            run_number,
            "Recovery: #{journey_id} went from FAIL to PASS"
          )
        )

      _ ->
        :ok
    end
  end

  # ──────────────────────────────────────────────
  # Timer management
  # ──────────────────────────────────────────────

  defp schedule_next(state) do
    ref = Process.send_after(self(), :tick, state.interval)
    %{state | timer_ref: ref}
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(%{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end
end
