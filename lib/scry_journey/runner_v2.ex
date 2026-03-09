defmodule ScryJourney.RunnerV2 do
  @moduledoc """
  Multi-step journey execution engine.

  Orchestrates step execution with context threading, check evaluation,
  teardown guarantee, dual timeouts (per-step and per-script), and
  structured event emission for visualization and recording.

  ## Event Emission

  Pass `emitter: fn` in opts to receive lifecycle events during execution.
  See `ScryJourney.EventEmitter` for emitter constructors and event types.

      emitter = ScryJourney.EventEmitter.collector()
      report = ScryJourney.RunnerV2.run(script, emitter: emitter)
      events = ScryJourney.EventEmitter.collect()
  """

  alias ScryJourney.{
    Context,
    Step,
    Checkpoint,
    ReportV2,
    EventEmitter,
    TelemetryCollector,
    Observer,
    Props
  }

  require Logger

  @default_script_timeout 30_000
  @max_script_timeout 120_000

  @doc """
  Run a journey script and return an aggregate report.

  The script map must have a `:steps` key with a list of step maps.
  Each step is executed in order with context threading. On first
  failure, remaining steps are skipped. Teardown always runs.

  ## Options

  - `:emitter` — event emission function, see `ScryJourney.EventEmitter`
  - `:props` — map of prop overrides, see `ScryJourney.Props`
  - `:default_step_timeout` — default per-step timeout in ms
  """
  @spec run(map(), keyword()) :: map()
  def run(script, opts \\ []) do
    script_timeout = clamp_timeout(script[:timeout_ms] || @default_script_timeout)
    emit = Keyword.get(opts, :emitter, EventEmitter.noop())
    journey_id = script[:id] || "journey_#{System.unique_integer([:positive])}"
    prop_overrides = Keyword.get(opts, :props, %{})
    opts = Keyword.put(opts, :journey_id, journey_id)

    # Resolve props from script declarations + overrides
    case Props.resolve(script, prop_overrides) do
      {:ok, props} ->
        opts = Keyword.put(opts, :props, props)
        run_with_props(script, opts, emit, script_timeout, journey_id)

      {:error, reason} ->
        ReportV2.build_error(script, "Props error: #{reason}")
    end
  end

  defp run_with_props(script, opts, emit, script_timeout, journey_id) do
    emit.(:journey_started, EventEmitter.journey_started(journey_id, script))

    task = Task.async(fn -> execute_all(script, opts, emit) end)

    report =
      case Task.yield(task, script_timeout) || Task.shutdown(task) do
        {:ok, report} ->
          report

        nil ->
          ReportV2.build_error(script, "Script timed out after #{script_timeout}ms")
      end

    emit.(:journey_completed, EventEmitter.journey_completed(journey_id, report))
    report
  end

  # -- Private --

  defp execute_all(script, opts, emit) do
    journey_id = Keyword.fetch!(opts, :journey_id)
    start_time = System.monotonic_time(:millisecond)
    {final_ctx, step_reports} = execute_steps(script, opts, emit)
    teardown_result = run_teardown(script, final_ctx)

    emit.(:teardown_completed, EventEmitter.teardown_completed(journey_id, teardown_result))

    # Build skipped reports for any steps not reached
    executed_count = length(step_reports)
    total_steps = length(script.steps)

    skipped_reports =
      if executed_count < total_steps do
        script.steps
        |> Enum.drop(executed_count)
        |> Enum.map(&ReportV2.build_step_skipped/1)
      else
        []
      end

    all_reports = step_reports ++ skipped_reports
    duration = System.monotonic_time(:millisecond) - start_time

    # Capture Prism graph summary when available
    graph = capture_graph_summary(journey_id)

    ReportV2.build(script, all_reports, %{
      duration_ms: duration,
      teardown: teardown_result,
      graph: graph
    })
  end

  defp execute_steps(script, opts, emit) do
    # Seed context with resolved props
    initial_ctx =
      case Keyword.get(opts, :props, %{}) do
        props when props == %{} -> Context.new()
        props -> Context.merge(Context.new(), %{props: props})
      end

    Enum.reduce_while(script.steps, {initial_ctx, []}, fn step, {ctx, reports} ->
      case execute_step(step, ctx, opts, emit) do
        {:ok, new_ctx, report} ->
          if report.status == "PASS" do
            {:cont, {new_ctx, reports ++ [report]}}
          else
            {:halt, {new_ctx, reports ++ [report]}}
          end

        {:error, report} ->
          {:halt, {ctx, reports ++ [report]}}
      end
    end)
  end

  defp execute_step(step, ctx, opts, emit) do
    journey_id = Keyword.fetch!(opts, :journey_id)
    start_time = System.monotonic_time(:millisecond)
    step_timeout = step[:timeout_ms] || opts[:default_step_timeout] || 5_000

    emit.(:step_started, EventEmitter.step_started(journey_id, step))

    # Wrap execution with telemetry collector and runtime observer
    {step_result, telemetry_data, observations} =
      execute_with_capture(step, ctx, step_timeout)

    case step_result do
      {:ok, result} ->
        # Merge telemetry and observations into result
        enriched =
          result
          |> maybe_merge_telemetry(telemetry_data)
          |> maybe_merge_observations(observations)

        new_ctx = Context.merge(ctx, enriched)

        # Run await if present
        await_result = run_await(step, new_ctx, journey_id, emit)

        # Evaluate checks against the merged context
        check_results = evaluate_checks(step, new_ctx, journey_id, emit)
        duration = System.monotonic_time(:millisecond) - start_time

        report =
          ReportV2.build_step(step, result, check_results, %{
            duration_ms: duration,
            await: format_await_result(await_result)
          })

        case await_result do
          {:error, _} ->
            failed_report = %{report | status: "FAIL", error: "Await condition timed out"}
            emit.(:step_completed, EventEmitter.step_completed(journey_id, step, failed_report))
            {:error, failed_report}

          _ ->
            emit.(:step_completed, EventEmitter.step_completed(journey_id, step, report))
            {:ok, new_ctx, report}
        end

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time
        report = ReportV2.build_step_error(step, reason, %{duration_ms: duration})
        emit.(:step_completed, EventEmitter.step_completed(journey_id, step, report))
        {:error, report}
    end
  end

  # Execute step with optional telemetry collection and runtime observation.
  # Returns {step_result, telemetry_data, observations}.
  defp execute_with_capture(step, ctx, timeout) do
    observe_opts = Map.get(step, :observe)

    run_fn = fn ->
      execute_with_telemetry(step, ctx, timeout)
    end

    if is_list(observe_opts) and observe_opts != [] do
      {{step_result, telemetry_data}, observations} = Observer.capture(observe_opts, run_fn)
      {step_result, telemetry_data, observations}
    else
      {step_result, telemetry_data} = run_fn.()
      {step_result, telemetry_data, Observer.empty_result()}
    end
  end

  defp execute_with_telemetry(%{telemetry: prefixes} = step, ctx, timeout)
       when is_list(prefixes) and prefixes != [] do
    TelemetryCollector.capture(prefixes, fn ->
      Step.execute(step, ctx, timeout_ms: timeout)
    end)
  end

  defp execute_with_telemetry(step, ctx, timeout) do
    {Step.execute(step, ctx, timeout_ms: timeout), TelemetryCollector.empty_result()}
  end

  defp maybe_merge_telemetry(result, telemetry_data) when telemetry_data.count > 0 do
    case result do
      r when is_map(r) -> Map.put(r, :telemetry, telemetry_data)
      _ -> %{result: result, telemetry: telemetry_data}
    end
  end

  defp maybe_merge_telemetry(result, _), do: result

  defp maybe_merge_observations(result, observations) when map_size(observations) > 0 do
    case result do
      r when is_map(r) -> Map.put(r, :observed, observations)
      _ -> %{result: result, observed: observations}
    end
  end

  defp maybe_merge_observations(result, _), do: result

  defp run_await(%{await: condition}, ctx, journey_id, emit) when is_tuple(condition) do
    step_id = "await"
    emit.(:await_started, EventEmitter.await_started(journey_id, %{id: step_id}, condition))
    result = Step.await(condition, ctx)
    emit.(:await_resolved, EventEmitter.await_resolved(journey_id, %{id: step_id}, result))
    result
  end

  defp run_await(_, _ctx, _journey_id, _emit), do: :no_await

  defp evaluate_checks(%{checks: checks}, ctx, journey_id, emit)
       when is_list(checks) and checks != [] do
    Enum.map(checks, fn check ->
      result = Checkpoint.evaluate(check, ctx)

      emit.(
        :checkpoint_evaluated,
        EventEmitter.checkpoint_evaluated(journey_id, %{id: check[:id]}, result)
      )

      result
    end)
  end

  defp evaluate_checks(_, _ctx, _journey_id, _emit), do: []

  defp run_teardown(%{teardown: teardown}, ctx) when is_function(teardown, 1) do
    start_time = System.monotonic_time(:millisecond)

    try do
      teardown.(ctx)
      duration = System.monotonic_time(:millisecond) - start_time
      %{status: "OK", duration_ms: duration}
    rescue
      e ->
        duration = System.monotonic_time(:millisecond) - start_time
        Logger.warning("Journey teardown failed: #{Exception.message(e)}")
        %{status: "ERROR", error: Exception.message(e), duration_ms: duration}
    end
  end

  defp run_teardown(%{teardown: {:code, code}}, ctx) when is_binary(code) do
    start_time = System.monotonic_time(:millisecond)

    if Code.ensure_loaded?(Scry.Evaluator) do
      bindings = Map.to_list(ctx)

      case apply(Scry.Evaluator, :eval, [code, [bindings: bindings, timeout: 5_000]]) do
        {:ok, _} ->
          duration = System.monotonic_time(:millisecond) - start_time
          %{status: "OK", duration_ms: duration}

        {:error, reason} ->
          duration = System.monotonic_time(:millisecond) - start_time
          Logger.warning("Journey teardown failed: #{inspect(reason)}")
          %{status: "ERROR", error: inspect(reason), duration_ms: duration}
      end
    else
      %{status: "ERROR", error: "Scry.Evaluator not available for code teardown"}
    end
  end

  defp run_teardown(_, _ctx), do: %{status: "OK"}

  defp format_await_result(:no_await), do: nil
  defp format_await_result({:ok, result}), do: result
  defp format_await_result({:error, result}), do: result

  defp clamp_timeout(ms) when is_integer(ms) and ms > 0, do: min(ms, @max_script_timeout)
  defp clamp_timeout(_), do: @default_script_timeout

  # Capture Prism graph summary for this journey if Prism is available.
  # Returns nil when Prism isn't loaded.
  defp capture_graph_summary(journey_id) do
    if Code.ensure_loaded?(Prism) and function_exported?(Prism, :snapshot, 0) do
      snapshot = apply(Prism, :snapshot, [])

      case ScryJourney.PrismQuery.journey_summary(snapshot, journey_id) do
        nil ->
          nil

        summary ->
          Map.take(summary, [
            :status,
            :step_count,
            :steps_passed,
            :steps_failed,
            :edge_count,
            :event_count
          ])
      end
    end
  end
end
