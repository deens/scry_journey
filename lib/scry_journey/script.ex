defmodule ScryJourney.Script do
  @moduledoc """
  Load and validate `.journey.exs` script files.

  A journey script is an `.exs` file whose last expression is a map with:
  - `:steps` — list of step maps (required)
  - `:id` — journey identifier (optional, defaults to filename)
  - `:name` — human-readable name (optional)
  - `:timeout_ms` — overall script timeout (optional, default 30_000)
  - `:teardown` — cleanup function (optional)
  """

  @default_timeout 30_000
  @max_timeout 120_000

  @doc """
  Load a `.journey.exs` file and return a normalized script map.

  The file is evaluated with `Code.eval_file/1`. The last expression
  must be a map containing a `:steps` key with a non-empty list.
  """
  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(path) do
    unless File.exists?(path) do
      {:error, {:file_not_found, path}}
    else
      do_load(path)
    end
  end

  @doc """
  Build a script map from inline arguments (MCP tool mode).

  Accepts a map with string keys (from JSON) and normalizes it
  into the same shape as a loaded .exs script, using code strings
  instead of anonymous functions.
  """
  @spec from_inline(map()) :: {:ok, map()} | {:error, term()}
  def from_inline(%{"steps" => steps} = args) when is_list(steps) and steps != [] do
    script = %{
      id: Map.get(args, "id", "inline"),
      name: Map.get(args, "name", "Inline Journey"),
      timeout_ms: clamp_timeout(Map.get(args, "timeout_ms", @default_timeout)),
      steps: Enum.map(steps, &normalize_inline_step/1),
      teardown: build_inline_teardown(Map.get(args, "teardown"))
    }

    {:ok, script}
  end

  def from_inline(%{"steps" => []}), do: {:error, {:validation_error, "steps must not be empty"}}
  def from_inline(_), do: {:error, {:validation_error, "missing required field: steps"}}

  # -- Private --

  defp do_load(path) do
    {result, _bindings} = Code.eval_file(path)

    case result do
      %{steps: steps} = script when is_list(steps) and steps != [] ->
        {:ok, normalize(script, path)}

      %{steps: []} ->
        {:error, {:validation_error, "steps must not be empty in #{path}"}}

      %{steps: _} ->
        {:error, {:validation_error, "steps must be a list in #{path}"}}

      _ ->
        {:error,
         {:invalid_script, "Expected a map with :steps key, got: #{inspect(result, limit: 50)}"}}
    end
  rescue
    e -> {:error, {:load_error, Exception.message(e)}}
  end

  defp normalize(script, path) do
    basename = Path.basename(path, ".journey.exs")

    script
    |> Map.put_new(:id, basename)
    |> Map.put_new(:name, Map.get(script, :id, basename))
    |> Map.put_new(:description, nil)
    |> Map.update(:timeout_ms, @default_timeout, &clamp_timeout/1)
    |> Map.update!(:steps, &normalize_steps/1)
  end

  defp normalize_steps(steps) do
    steps
    |> Enum.with_index(1)
    |> Enum.map(fn {step, idx} ->
      step
      |> Map.put_new(:id, "step_#{idx}")
      |> Map.put_new(:name, step[:id] || "Step #{idx}")
      |> Map.put_new(:checks, [])
      |> normalize_step_checks()
    end)
  end

  defp normalize_step_checks(step) do
    checks =
      step.checks
      |> Enum.with_index(1)
      |> Enum.map(fn {check, idx} ->
        check
        |> Map.put_new(:id, "#{step.id}_check_#{idx}")
        |> ensure_string_keys_for_assert()
      end)

    %{step | checks: checks}
  end

  defp ensure_string_keys_for_assert(check) do
    # Checkpoint.evaluate expects string "assert" values
    case check do
      %{assert: assert} when is_atom(assert) -> %{check | assert: Atom.to_string(assert)}
      _ -> check
    end
  end

  defp normalize_inline_step(step) when is_map(step) do
    %{
      id: Map.get(step, "id", "step"),
      name: Map.get(step, "name", Map.get(step, "id", "Step")),
      code: Map.get(step, "code"),
      timeout_ms: Map.get(step, "timeout_ms"),
      await: normalize_inline_await(Map.get(step, "await")),
      checks: normalize_inline_checks(Map.get(step, "checks", []))
    }
  end

  defp normalize_inline_await(nil), do: nil

  defp normalize_inline_await(%{"type" => type} = await) do
    case type do
      "process_state" ->
        {:process_state, Map.get(await, "target"), Map.get(await, "path", []),
         safe_to_atom(Map.get(await, "check", "equals")), Map.get(await, "expected")}

      "eval" ->
        {:eval, Map.get(await, "expression")}

      "process_alive" ->
        {:process_alive, Map.get(await, "target")}

      "process_dead" ->
        {:process_dead, Map.get(await, "target")}

      "ets_entry" ->
        {:ets_entry, safe_to_atom(Map.get(await, "target")), Map.get(await, "expected")}

      _ ->
        nil
    end
  end

  defp normalize_inline_await(_), do: nil

  defp normalize_inline_checks(checks) when is_list(checks) do
    checks
    |> Enum.with_index(1)
    |> Enum.map(fn {check, idx} ->
      base = %{
        id: Map.get(check, "id", "check_#{idx}"),
        path: Map.get(check, "path"),
        assert: Map.get(check, "assert")
      }

      base
      |> maybe_put(:expected, Map.get(check, "expected"))
      |> maybe_put(:min, Map.get(check, "min"))
      |> maybe_put(:values, Map.get(check, "values"))
    end)
  end

  defp normalize_inline_checks(_), do: []

  defp build_inline_teardown(nil), do: nil
  defp build_inline_teardown(code) when is_binary(code), do: {:code, code}
  defp build_inline_teardown(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp safe_to_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    _ -> String.to_atom(value)
  end

  defp safe_to_atom(value) when is_atom(value), do: value

  defp clamp_timeout(ms) when is_integer(ms) and ms > 0, do: min(ms, @max_timeout)
  defp clamp_timeout(_), do: @default_timeout
end
