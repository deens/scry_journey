defmodule ScryJourney.Runner do
  @moduledoc """
  Execute journey cards and evaluate checkpoints.

  Supports two execution transports:
  - `:local` — call the function directly via `apply/3`
  - `:scry` — call via Scry RPC to a remote node (requires optional scry dependency)

  The runner resolves the module and function from the card's execution spec,
  calls it with the specified args and timeout, then evaluates all checkpoints
  against the result.
  """

  alias ScryJourney.{Checkpoint, Report}

  @default_timeout_ms 5_000

  @doc "Run a journey card and return a report with checkpoint results."
  @spec run(map(), keyword()) :: map()
  def run(card, opts \\ []) do
    timeout_ms = resolve_timeout(card, opts)
    transport = Keyword.get(opts, :transport, :local)

    case execute(card.execution, transport, timeout_ms, opts) do
      {:ok, result} ->
        checkpoint_results =
          Enum.map(card.checkpoints, &Checkpoint.evaluate(&1, result))

        Report.build(card, checkpoint_results, %{
          transport: to_string(transport),
          timeout_ms: timeout_ms,
          result: result
        })

      {:error, reason} ->
        Report.build_error(card, reason)
    end
  end

  # Execution

  defp execute(execution, :local, timeout_ms, _opts) do
    run_spec = execution.run

    with {:ok, module} <- resolve_module(run_spec.module),
         {:ok, function} <- resolve_function(run_spec.function) do
      execute_with_timeout(module, function, run_spec.args, timeout_ms)
    end
  end

  defp execute(execution, :scry, timeout_ms, opts) do
    node = Keyword.get(opts, :node)
    run_spec = execution.run

    with {:ok, module} <- resolve_module(run_spec.module),
         {:ok, function} <- resolve_function(run_spec.function) do
      execute_via_scry(module, function, run_spec.args, node, timeout_ms)
    end
  end

  defp execute(_execution, transport, _timeout_ms, _opts) do
    {:error, "Unsupported transport: #{inspect(transport)}"}
  end

  defp execute_with_timeout(module, function, args, timeout_ms) do
    task =
      Task.async(fn ->
        try do
          result = apply(module, function, args)
          {:ok, normalize_result(result)}
        rescue
          e -> {:error, "Execution error: #{Exception.message(e)}"}
        catch
          kind, reason -> {:error, "Execution #{kind}: #{inspect(reason)}"}
        end
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, "Execution timed out after #{timeout_ms}ms"}
    end
  end

  defp execute_via_scry(module, function, args, node, timeout_ms) do
    if Code.ensure_loaded?(Scry.CLI) do
      case Scry.CLI.rpc_call(node, module, function, args, rpc_timeout: timeout_ms) do
        {:ok, result} -> {:ok, normalize_result(result)}
        {:error, reason} -> {:error, "Scry RPC error: #{inspect(reason)}"}
        other -> {:ok, normalize_result(other)}
      end
    else
      {:error, "Scry is not available. Add :scry to your dependencies for remote execution."}
    end
  end

  defp resolve_module(module_string) when is_binary(module_string) do
    module_atom =
      if String.starts_with?(module_string, "Elixir.") do
        String.to_atom(module_string)
      else
        String.to_atom("Elixir." <> module_string)
      end

    {:ok, module_atom}
  end

  defp resolve_function(function_string) when is_binary(function_string) do
    {:ok, String.to_atom(function_string)}
  end

  defp resolve_timeout(card, opts) do
    case Keyword.get(opts, :timeout_ms) do
      nil ->
        case card do
          %{execution: %{run: %{timeout_ms: t}}} when is_integer(t) and t > 0 -> t
          _ -> @default_timeout_ms
        end

      timeout_ms when is_integer(timeout_ms) and timeout_ms > 0 ->
        timeout_ms

      _ ->
        @default_timeout_ms
    end
  end

  defp normalize_result(result) when is_map(result), do: result
  defp normalize_result({:ok, value}) when is_map(value), do: value
  defp normalize_result(other), do: %{result: other}
end
