defmodule ScryJourney.Step do
  @moduledoc """
  Single step execution with timeout and optional await.

  Handles two step types:
  - Function steps (`.journey.exs` files): `%{run: fn ctx -> ... end}`
  - Code string steps (inline MCP mode): `%{code: "expression"}`
  """

  alias ScryJourney.Context

  @default_timeout 5_000
  @max_step_timeout 30_000

  @doc """
  Execute a single step and return its result.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  """
  @spec execute(map(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def execute(%{run: run}, context, opts) when is_function(run, 1) do
    timeout = clamp_timeout(opts[:timeout_ms] || @default_timeout)
    execute_with_timeout(fn -> run.(context) end, timeout)
  end

  def execute(%{code: code}, context, opts) when is_binary(code) do
    timeout = clamp_timeout(opts[:timeout_ms] || @default_timeout)

    if Code.ensure_loaded?(Scry.Evaluator) do
      bindings = Map.to_list(context)
      apply(Scry.Evaluator, :eval, [code, [bindings: bindings, timeout: timeout]])
    else
      {:error, "Scry.Evaluator is not available. Code string steps require the :scry dependency."}
    end
  end

  def execute(step, _context, _opts) do
    {:error, "Step #{inspect(step[:id])} has no :run function or :code string"}
  end

  @doc """
  Wait for a condition to be satisfied after step execution.

  Delegates to `Scry.Probe.Waiter.probe_wait/2` when available,
  falls back to a simple poll loop for basic conditions.
  """
  @spec await(tuple(), map(), keyword()) :: {:ok, map()} | {:error, map()}
  def await(condition, context, opts \\ []) do
    resolved = Context.resolve_condition(condition, context)
    timeout = opts[:timeout_ms] || @default_timeout

    if Code.ensure_loaded?(Scry.Probe.Waiter) do
      apply(Scry.Probe.Waiter, :probe_wait, [resolved, [timeout: timeout]])
    else
      simple_poll(resolved, timeout)
    end
  end

  # -- Private --

  defp execute_with_timeout(fun, timeout) do
    task =
      Task.async(fn ->
        try do
          case fun.() do
            {:error, reason} -> {:error, reason}
            result -> {:ok, result}
          end
        rescue
          e -> {:error, Exception.message(e)}
        catch
          kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  end

  defp simple_poll(condition, timeout, interval \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll(condition, deadline, interval)
  end

  defp do_poll(condition, deadline, interval) do
    now = System.monotonic_time(:millisecond)

    if now > deadline do
      {:error, %{matched: false, waited_ms: 0, reason: :timeout}}
    else
      case evaluate_simple_condition(condition) do
        true ->
          {:ok, %{matched: true, waited_ms: 0}}

        false ->
          Process.sleep(interval)
          do_poll(condition, deadline, interval)
      end
    end
  end

  defp evaluate_simple_condition({:eval, expr}) when is_binary(expr) do
    if Code.ensure_loaded?(Scry.Evaluator) do
      case apply(Scry.Evaluator, :eval, [expr, []]) do
        {:ok, result} -> result not in [nil, false]
        _ -> false
      end
    else
      false
    end
  end

  defp evaluate_simple_condition({:process_alive, process}) do
    case resolve_process(process) do
      pid when is_pid(pid) -> Process.alive?(pid)
      _ -> false
    end
  end

  defp evaluate_simple_condition({:process_dead, process}) do
    case resolve_process(process) do
      pid when is_pid(pid) -> not Process.alive?(pid)
      nil -> true
      _ -> false
    end
  end

  defp evaluate_simple_condition(_), do: false

  defp resolve_process(pid) when is_pid(pid), do: pid
  defp resolve_process(name) when is_atom(name), do: Process.whereis(name)
  defp resolve_process(_), do: nil

  defp clamp_timeout(ms) when is_integer(ms) and ms > 0, do: min(ms, @max_step_timeout)
  defp clamp_timeout(_), do: @default_timeout
end
