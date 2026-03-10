defmodule ScryJourney.EventEmitter do
  @moduledoc """
  Structured event emission during journey execution.

  EventEmitter provides a composable way to broadcast lifecycle events
  from RunnerV2. Events are shaped for Prism consumption — each event
  has a type, journey context, and type-specific payload.

  ## Usage

  An emitter is a function `(event_type, payload) -> :ok`. The default
  emitter is a no-op. Compose multiple emitters with `combine/1`.

      # Single emitter
      emitter = EventEmitter.new(fn type, payload -> IO.inspect({type, payload}) end)

      # PubSub emitter
      emitter = EventEmitter.pubsub(MyApp.PubSub, "scry:journey:my_run")

      # Combined
      emitter = EventEmitter.combine([
        EventEmitter.pubsub(MyApp.PubSub, topic),
        EventEmitter.collector()
      ])

      # Pass to runner
      ScryJourney.RunnerV2.run(script, emitter: emitter)

  ## Event Types

  All events include `:journey_id` and `:timestamp_ms`.

  - `:journey_started` — journey begins execution
  - `:step_started` — a step begins
  - `:step_completed` — a step finishes (pass, fail, or error)
  - `:checkpoint_evaluated` — a single checkpoint assertion result
  - `:await_started` — an await condition begins polling
  - `:await_resolved` — an await condition resolves (matched or timed out)
  - `:journey_completed` — journey finishes with final report
  - `:teardown_completed` — teardown finishes
  """

  @type emitter :: (atom(), map() -> :ok)

  @doc "Create an emitter from a function."
  @spec new((atom(), map() -> :ok)) :: emitter()
  def new(fun) when is_function(fun, 2), do: fun

  @doc "A no-op emitter that discards all events."
  @spec noop() :: emitter()
  def noop, do: fn _type, _payload -> :ok end

  @doc """
  Create a PubSub emitter that broadcasts events to a topic.

  Events are broadcast as `{:journey_event, type, payload}` tuples.
  Gracefully degrades if Phoenix.PubSub is not available.
  """
  @spec pubsub(module(), String.t()) :: emitter()
  def pubsub(pubsub_mod, topic) when is_atom(pubsub_mod) and is_binary(topic) do
    fn type, payload ->
      if Code.ensure_loaded?(Phoenix.PubSub) do
        apply(Phoenix.PubSub, :broadcast, [pubsub_mod, topic, {:journey_event, type, payload}])
      end

      :ok
    end
  end

  @doc """
  Create a Prism emitter that feeds journey events into Prism's graph.

  Auto-detects whether Prism is available. Returns a noop if Prism is not loaded.
  When Prism is running, journey events appear as nodes, edges, and timeline
  events in the Prism visualization.

  ## Examples

      emitter = EventEmitter.prism()
      ScryJourney.run_script(script, emitter: emitter)
  """
  @spec prism() :: emitter()
  def prism do
    if prism_available?() do
      apply(Prism, :journey_emitter, [])
    else
      noop()
    end
  end

  @doc "Check if Prism is loaded and has journey_emitter/0."
  @spec prism_available?() :: boolean()
  def prism_available? do
    Code.ensure_loaded?(Prism) and function_exported?(Prism, :journey_emitter, 0)
  end

  @doc """
  Create a collector emitter that stores events in the calling process mailbox.

  Use `collect/1` to retrieve stored events. Useful for testing and recording.
  """
  @spec collector(pid()) :: emitter()
  def collector(target \\ self()) do
    fn type, payload ->
      send(target, {:journey_event, type, payload})
      :ok
    end
  end

  @doc """
  Retrieve all collected events from the process mailbox.

  Returns events in emission order (oldest first).
  """
  @spec collect(timeout()) :: [{atom(), map()}]
  def collect(timeout \\ 0) do
    collect_loop([], timeout)
  end

  defp collect_loop(acc, timeout) do
    receive do
      {:journey_event, type, payload} ->
        collect_loop([{type, payload} | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end

  @doc """
  Combine multiple emitters into one. All emitters receive every event.
  """
  @spec combine([emitter()]) :: emitter()
  def combine(emitters) when is_list(emitters) do
    fn type, payload ->
      Enum.each(emitters, fn emit -> emit.(type, payload) end)
      :ok
    end
  end

  # -- Event builders --

  @doc false
  def journey_started(journey_id, script) do
    %{
      journey_id: journey_id,
      name: script[:name],
      step_count: length(script[:steps] || []),
      timeout_ms: script[:timeout_ms],
      timestamp_ms: now()
    }
  end

  @doc false
  def step_started(journey_id, step) do
    %{
      journey_id: journey_id,
      step_id: step[:id],
      step_name: step[:name],
      timestamp_ms: now()
    }
  end

  @doc false
  def step_completed(journey_id, step, report) do
    %{
      journey_id: journey_id,
      step_id: step[:id],
      step_name: step[:name],
      status: report.status,
      duration_ms: report.duration_ms,
      check_count: length(Map.get(report, :checks, [])),
      error: report[:error],
      timestamp_ms: now()
    }
  end

  @doc false
  def checkpoint_evaluated(journey_id, step, check_result) do
    %{
      journey_id: journey_id,
      step_id: step[:id],
      check_id: check_result.id,
      status: check_result.status,
      path: check_result.path,
      assert: check_result.assert,
      message: check_result.message,
      timestamp_ms: now()
    }
  end

  @doc false
  def await_started(journey_id, step, condition) do
    await_id = inspect(condition, limit: 50)

    %{
      journey_id: journey_id,
      step_id: step[:id],
      await_id: await_id,
      condition: await_id,
      timestamp_ms: now()
    }
  end

  @doc false
  def await_resolved(journey_id, step, result) do
    {status, detail} =
      case result do
        {:ok, data} -> {"matched", data}
        {:error, data} -> {"timeout", data}
        :no_await -> {"skipped", nil}
      end

    %{
      journey_id: journey_id,
      step_id: step[:id],
      await_id: step[:id],
      status: status,
      detail: detail,
      timestamp_ms: now()
    }
  end

  @doc false
  def journey_completed(journey_id, report) do
    %{
      journey_id: journey_id,
      status: report.status,
      pass: report.pass,
      duration_ms: report.duration_ms,
      step_counts: report.step_counts,
      check_counts: report.check_counts,
      timestamp_ms: now()
    }
  end

  @doc false
  def teardown_completed(journey_id, result) do
    %{
      journey_id: journey_id,
      status: result[:status] || "OK",
      error: result[:error],
      duration_ms: result[:duration_ms] || 0,
      timestamp_ms: now()
    }
  end

  # -- Mode event builders --

  @doc false
  def mode_started(journey_id, script, opts) do
    %{
      journey_id: journey_id,
      name: script[:name],
      step_count: length(script[:steps] || []),
      interval_ms: Keyword.get(opts, :interval),
      props_mode: Keyword.get(opts, :props_mode, :fixed),
      timestamp_ms: now()
    }
  end

  @doc false
  def mode_tick(journey_id, report, run_stats) do
    %{
      journey_id: journey_id,
      run: run_stats.run,
      status: run_stats.status,
      pass: report.pass,
      duration_ms: report.duration_ms,
      total_runs: run_stats.run,
      total_passes: run_stats.passes,
      total_failures: run_stats.failures,
      pass_rate: safe_rate(run_stats.passes, run_stats.run),
      regressions: run_stats.regressions,
      recoveries: run_stats.recoveries,
      props: run_stats[:props],
      timestamp_ms: now()
    }
  end

  @doc false
  def mode_regression(journey_id, run_number, message) do
    %{
      journey_id: journey_id,
      run: run_number,
      message: message,
      timestamp_ms: now()
    }
  end

  @doc false
  def mode_recovered(journey_id, run_number, message) do
    %{
      journey_id: journey_id,
      run: run_number,
      message: message,
      timestamp_ms: now()
    }
  end

  defp safe_rate(_n, 0), do: 0.0
  defp safe_rate(n, total), do: Float.round(n / total, 3)

  defp now, do: System.monotonic_time(:millisecond)
end
