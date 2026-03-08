defmodule ScryJourney.RunnerV2 do
  @moduledoc """
  Multi-step journey execution engine.

  Orchestrates step execution with context threading, check evaluation,
  teardown guarantee, and dual timeouts (per-step and per-script).
  """

  alias ScryJourney.{Context, Step, Checkpoint, ReportV2}

  require Logger

  @default_script_timeout 30_000
  @max_script_timeout 120_000

  @doc """
  Run a journey script and return an aggregate report.

  The script map must have a `:steps` key with a list of step maps.
  Each step is executed in order with context threading. On first
  failure, remaining steps are skipped. Teardown always runs.
  """
  @spec run(map(), keyword()) :: map()
  def run(script, opts \\ []) do
    script_timeout = clamp_timeout(script[:timeout_ms] || @default_script_timeout)

    task = Task.async(fn -> execute_all(script, opts) end)

    case Task.yield(task, script_timeout) || Task.shutdown(task) do
      {:ok, report} ->
        report

      nil ->
        ReportV2.build_error(script, "Script timed out after #{script_timeout}ms")
    end
  end

  # -- Private --

  defp execute_all(script, opts) do
    start_time = System.monotonic_time(:millisecond)
    {final_ctx, step_reports} = execute_steps(script, opts)
    teardown_result = run_teardown(script, final_ctx)

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

    ReportV2.build(script, all_reports, %{
      duration_ms: duration,
      teardown: teardown_result
    })
  end

  defp execute_steps(script, opts) do
    Enum.reduce_while(script.steps, {Context.new(), []}, fn step, {ctx, reports} ->
      case execute_step(step, ctx, opts) do
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

  defp execute_step(step, ctx, opts) do
    start_time = System.monotonic_time(:millisecond)
    step_timeout = step[:timeout_ms] || opts[:default_step_timeout] || 5_000

    case Step.execute(step, ctx, timeout_ms: step_timeout) do
      {:ok, result} ->
        new_ctx = Context.merge(ctx, result)

        # Run await if present
        await_result = run_await(step, new_ctx)

        # Evaluate checks against the merged context
        check_results = evaluate_checks(step, new_ctx)
        duration = System.monotonic_time(:millisecond) - start_time

        report =
          ReportV2.build_step(step, result, check_results, %{
            duration_ms: duration,
            await: format_await_result(await_result)
          })

        case await_result do
          {:error, _} ->
            # Await failure is a step failure
            failed_report = %{report | status: "FAIL", error: "Await condition timed out"}
            {:error, failed_report}

          _ ->
            {:ok, new_ctx, report}
        end

      {:error, reason} ->
        duration = System.monotonic_time(:millisecond) - start_time
        report = ReportV2.build_step_error(step, reason, %{duration_ms: duration})
        {:error, report}
    end
  end

  defp run_await(%{await: condition}, ctx) when is_tuple(condition) do
    Step.await(condition, ctx)
  end

  defp run_await(_, _ctx), do: :no_await

  defp evaluate_checks(%{checks: checks}, ctx) when is_list(checks) and checks != [] do
    Enum.map(checks, &Checkpoint.evaluate(&1, ctx))
  end

  defp evaluate_checks(_, _ctx), do: []

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
end
