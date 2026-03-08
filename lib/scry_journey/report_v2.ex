defmodule ScryJourney.ReportV2 do
  @moduledoc """
  Build structured reports from journey v2 script execution.

  Produces per-step reports and an aggregate summary with
  step/check counts, duration tracking, and teardown status.
  """

  @schema_version "journey_script/v2"

  @doc "Build an aggregate report from a script and its step reports."
  @spec build(map(), [map()], map()) :: map()
  def build(script, step_reports, meta \\ %{}) do
    pass_steps = Enum.count(step_reports, &(&1.status == "PASS"))
    fail_steps = Enum.count(step_reports, &(&1.status == "FAIL"))
    error_steps = Enum.count(step_reports, &(&1.status == "ERROR"))
    skip_steps = Enum.count(step_reports, &(&1.status == "SKIPPED"))

    {check_pass, check_fail} = count_checks(step_reports)

    all_pass = fail_steps == 0 and error_steps == 0

    %{
      id: script[:id],
      name: script[:name],
      schema_version: @schema_version,
      status: if(all_pass, do: "PASS", else: "FAIL"),
      pass: all_pass,
      duration_ms: Map.get(meta, :duration_ms, 0),
      steps: step_reports,
      step_counts: %{pass: pass_steps, fail: fail_steps, skipped: skip_steps, error: error_steps},
      check_counts: %{pass: check_pass, fail: check_fail},
      teardown: Map.get(meta, :teardown, %{status: "OK"})
    }
  end

  @doc "Build a step report for a successful step."
  @spec build_step(map(), term(), [map()], map()) :: map()
  def build_step(step, result, check_results, meta \\ %{}) do
    any_failed = Enum.any?(check_results, &(&1.status == "FAIL"))

    %{
      step_id: step[:id],
      step_name: step[:name],
      status: if(any_failed, do: "FAIL", else: "PASS"),
      duration_ms: Map.get(meta, :duration_ms, 0),
      result: safe_inspect_result(result),
      await: Map.get(meta, :await),
      checks: check_results,
      error: nil
    }
  end

  @doc "Build a step report for a failed/errored step."
  @spec build_step_error(map(), term(), map()) :: map()
  def build_step_error(step, reason, meta \\ %{}) do
    %{
      step_id: step[:id],
      step_name: step[:name],
      status: "ERROR",
      duration_ms: Map.get(meta, :duration_ms, 0),
      result: nil,
      await: nil,
      checks: [],
      error: format_error(reason)
    }
  end

  @doc "Build a step report for a skipped step."
  @spec build_step_skipped(map()) :: map()
  def build_step_skipped(step) do
    %{
      step_id: step[:id],
      step_name: step[:name],
      status: "SKIPPED",
      duration_ms: 0,
      result: nil,
      await: nil,
      checks: [],
      error: nil
    }
  end

  @doc "Build an error report for a script-level failure."
  @spec build_error(map(), term()) :: map()
  def build_error(script, reason) do
    %{
      id: script[:id],
      name: script[:name],
      schema_version: @schema_version,
      status: "ERROR",
      pass: false,
      duration_ms: 0,
      steps: [],
      step_counts: %{pass: 0, fail: 0, skipped: 0, error: 0},
      check_counts: %{pass: 0, fail: 0},
      teardown: %{status: "OK"},
      error: format_error(reason)
    }
  end

  # -- Private --

  defp count_checks(step_reports) do
    Enum.reduce(step_reports, {0, 0}, fn report, {pass, fail} ->
      checks = Map.get(report, :checks, [])
      p = Enum.count(checks, &(&1.status == "PASS"))
      f = Enum.count(checks, &(&1.status == "FAIL"))
      {pass + p, fail + f}
    end)
  end

  defp safe_inspect_result(result) when is_map(result), do: result
  defp safe_inspect_result(result), do: inspect(result, limit: 200)

  defp format_error(:timeout), do: "Step timed out"
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
