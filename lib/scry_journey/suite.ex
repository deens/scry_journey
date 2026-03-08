defmodule ScryJourney.Suite do
  @moduledoc """
  Run multiple journey cards and produce an aggregate report.

  Discovers all `.journey.json` files in a directory and runs them,
  producing a summary with per-journey results and overall pass/fail.

  ## Usage

      # Run all journeys in a directory
      report = ScryJourney.Suite.run("journeys/")

      # With options
      report = ScryJourney.Suite.run("journeys/", transport: :scry, node: :"myapp@localhost")

      report.pass       # => true if ALL journeys pass
      report.summary    # => %{total: 4, passed: 3, failed: 1, errors: 0}
      report.results    # => [%{card_id: ..., pass: true, ...}, ...]
  """

  @doc """
  Run all journey cards found in a directory or list of paths.

  Accepts either a directory path (discovers all `.journey.json` files)
  or a list of file paths.

  Returns an aggregate report map.
  """
  @spec run(String.t() | [String.t()], keyword()) :: map()
  def run(dir_or_paths, opts \\ [])

  def run(paths, opts) when is_list(paths) do
    results =
      paths
      |> Enum.sort()
      |> Enum.map(fn path -> run_one(path, opts) end)

    build_suite_report(results)
  end

  def run(dir, opts) when is_binary(dir) do
    paths = discover(dir)

    if paths == [] do
      %{
        pass: true,
        status: "EMPTY",
        summary: %{total: 0, passed: 0, failed: 0, errors: 0},
        results: [],
        directory: dir
      }
    else
      dir
      |> discover()
      |> run(opts)
      |> Map.put(:directory, dir)
    end
  end

  @doc "Discover all .journey.json and .journey.exs files in a directory, sorted alphabetically."
  @spec discover(String.t()) :: [String.t()]
  def discover(dir) do
    json = Path.join(dir, "**/*.journey.json") |> Path.wildcard()
    exs = Path.join(dir, "**/*.journey.exs") |> Path.wildcard()

    (json ++ exs) |> Enum.sort()
  end

  defp run_one(path, opts) do
    if String.ends_with?(path, ".journey.exs") do
      run_script(path, opts)
    else
      run_card(path, opts)
    end
  end

  defp run_card(path, opts) do
    case ScryJourney.verify(path, opts) do
      {:ok, report} ->
        report

      {:error, reason} ->
        %{
          card_id: Path.basename(path, ".journey.json"),
          card_name: Path.basename(path),
          pass: false,
          status: "ERROR",
          error: format_error(reason),
          checkpoints: [],
          checkpoint_counts: %{pass: 0, fail: 0}
        }
    end
  end

  defp run_script(path, opts) do
    case ScryJourney.verify_script(path, opts) do
      {:ok, report} ->
        report

      {:error, reason} ->
        %{
          id: Path.basename(path, ".journey.exs"),
          name: Path.basename(path),
          pass: false,
          status: "ERROR",
          error: format_error(reason),
          steps: [],
          step_counts: %{pass: 0, fail: 0, skipped: 0, error: 0},
          check_counts: %{pass: 0, fail: 0}
        }
    end
  end

  defp build_suite_report(results) do
    passed = Enum.count(results, & &1.pass)
    failed = Enum.count(results, &(&1.status == "FAIL"))
    errors = Enum.count(results, &(&1.status == "ERROR"))
    total = length(results)

    %{
      pass: passed == total,
      status: if(passed == total, do: "PASS", else: "FAIL"),
      summary: %{
        total: total,
        passed: passed,
        failed: failed,
        errors: errors
      },
      results: results
    }
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
