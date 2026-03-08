defmodule ScryJourney.Card do
  @moduledoc """
  Load and normalize journey card JSON files.

  A journey card defines an executable feature contract:
  - `execution` — which module/function to call
  - `checkpoints` — assertions to verify on the result

  ## Card Format (v1)

      {
        "schema_version": "journey_card/v1",
        "id": "user_registration",
        "name": "User Registration Flow",
        "execution": {
          "type": "module_call",
          "run": {"module": "MyApp.Journeys", "function": "run", "args": [5000], "timeout_ms": 10000}
        },
        "checkpoints": [
          {"id": "user_created", "path": "user.id", "assert": "present"}
        ]
      }
  """

  @schema_version "journey_card/v1"
  @default_timeout_ms 5_000

  @assertions ~w(non_empty_string equals not_equals one_of integer_gte gte lte gt lt contains truthy falsy present length_equals type_is matches has_key)

  @doc "Load a journey card from a JSON file path."
  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(path) when is_binary(path) do
    with {:ok, content} <- File.read(path),
         {:ok, decoded} <- Jason.decode(content),
         {:ok, card} <- normalize(decoded) do
      {:ok, card}
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error, "Invalid JSON in #{path}: #{Exception.message(error)}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Normalize a decoded JSON map into a validated journey card."
  @spec normalize(map()) :: {:ok, map()} | {:error, String.t()}
  def normalize(raw) when is_map(raw) do
    with :ok <- validate_schema_version(raw),
         {:ok, card_id} <- fetch_non_empty(raw, "id"),
         {:ok, card_name} <- fetch_non_empty(raw, "name"),
         {:ok, execution} <- normalize_execution(raw),
         {:ok, checkpoints} <- normalize_checkpoints(raw) do
      {:ok,
       %{
         schema_version: @schema_version,
         id: card_id,
         name: card_name,
         description: fetch_string(raw, "description"),
         execution: execution,
         checkpoints: checkpoints
       }}
    end
  end

  def normalize(_raw), do: {:error, "Journey card must be a JSON object"}

  @doc "Returns the default timeout in milliseconds."
  def default_timeout_ms, do: @default_timeout_ms

  @doc "Returns the current schema version."
  def schema_version, do: @schema_version

  # Validation

  defp validate_schema_version(raw) do
    case fetch_string(raw, "schema_version") do
      @schema_version -> :ok
      value -> {:error, "schema_version must be #{@schema_version}, got: #{inspect(value)}"}
    end
  end

  defp normalize_execution(raw) do
    execution = fetch_map(raw, "execution")

    with execution when is_map(execution) <- execution,
         {:ok, type} <- fetch_non_empty(execution, "type"),
         :ok <- validate_execution_type(type),
         {:ok, run} <- normalize_run_spec(execution) do
      {:ok, %{type: type, run: run}}
    else
      nil -> {:error, "execution is required"}
      {:error, reason} -> {:error, reason}
      _ -> {:error, "execution must be an object"}
    end
  end

  defp normalize_run_spec(execution) do
    run = fetch_map(execution, "run")

    with run when is_map(run) <- run,
         {:ok, run_module} <- fetch_non_empty(run, "module"),
         {:ok, run_function} <- fetch_non_empty(run, "function"),
         {:ok, args} <- normalize_args(run),
         {:ok, timeout_ms} <- normalize_timeout(run) do
      {:ok,
       %{
         module: run_module,
         function: run_function,
         args: args,
         timeout_ms: timeout_ms
       }}
    else
      nil -> {:error, "execution.run is required"}
      {:error, reason} -> {:error, reason}
      _ -> {:error, "execution.run must be an object"}
    end
  end

  defp normalize_checkpoints(raw) do
    case fetch_value(raw, "checkpoints") do
      checkpoints when is_list(checkpoints) and checkpoints != [] ->
        checkpoints
        |> Enum.with_index(1)
        |> Enum.reduce_while({:ok, []}, fn {checkpoint, index}, {:ok, acc} ->
          case normalize_checkpoint(checkpoint, index) do
            {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
          error -> error
        end

      checkpoints when is_list(checkpoints) ->
        {:error, "checkpoints must not be empty"}

      _ ->
        {:error, "checkpoints must be an array"}
    end
  end

  defp normalize_checkpoint(checkpoint, index) when is_map(checkpoint) do
    with {:ok, checkpoint_id} <- fetch_non_empty(checkpoint, "id"),
         {:ok, path} <- fetch_non_empty(checkpoint, "path"),
         {:ok, assertion} <- fetch_non_empty(checkpoint, "assert"),
         :ok <- validate_assertion(assertion),
         {:ok, extra_args} <- normalize_checkpoint_args(assertion, checkpoint) do
      {:ok, Map.merge(%{id: checkpoint_id, path: path, assert: assertion}, extra_args)}
    else
      {:error, reason} -> {:error, "checkpoint ##{index}: #{reason}"}
    end
  end

  defp normalize_checkpoint(_checkpoint, index) do
    {:error, "checkpoint ##{index} must be an object"}
  end

  defp normalize_checkpoint_args("equals", checkpoint) do
    if map_has_key?(checkpoint, "expected"),
      do: {:ok, %{expected: fetch_value(checkpoint, "expected")}},
      else: {:error, "assert=equals requires expected"}
  end

  defp normalize_checkpoint_args("not_equals", checkpoint) do
    if map_has_key?(checkpoint, "expected"),
      do: {:ok, %{expected: fetch_value(checkpoint, "expected")}},
      else: {:error, "assert=not_equals requires expected"}
  end

  defp normalize_checkpoint_args("matches", checkpoint) do
    case fetch_value(checkpoint, "expected") do
      pattern when is_binary(pattern) and pattern != "" -> {:ok, %{expected: pattern}}
      _ -> {:error, "assert=matches requires string expected (regex pattern)"}
    end
  end

  defp normalize_checkpoint_args("has_key", checkpoint) do
    case fetch_value(checkpoint, "expected") do
      key when is_binary(key) and key != "" -> {:ok, %{expected: key}}
      _ -> {:error, "assert=has_key requires string expected (key name)"}
    end
  end

  defp normalize_checkpoint_args("gte", checkpoint) do
    case fetch_value(checkpoint, "expected") do
      n when is_number(n) -> {:ok, %{expected: n}}
      _ -> {:error, "assert=gte requires numeric expected"}
    end
  end

  defp normalize_checkpoint_args("lte", checkpoint) do
    case fetch_value(checkpoint, "expected") do
      n when is_number(n) -> {:ok, %{expected: n}}
      _ -> {:error, "assert=lte requires numeric expected"}
    end
  end

  defp normalize_checkpoint_args("gt", checkpoint) do
    case fetch_value(checkpoint, "expected") do
      n when is_number(n) -> {:ok, %{expected: n}}
      _ -> {:error, "assert=gt requires numeric expected"}
    end
  end

  defp normalize_checkpoint_args("lt", checkpoint) do
    case fetch_value(checkpoint, "expected") do
      n when is_number(n) -> {:ok, %{expected: n}}
      _ -> {:error, "assert=lt requires numeric expected"}
    end
  end

  defp normalize_checkpoint_args("one_of", checkpoint) do
    case fetch_value(checkpoint, "values") do
      values when is_list(values) and values != [] -> {:ok, %{values: values}}
      _ -> {:error, "assert=one_of requires non-empty values"}
    end
  end

  defp normalize_checkpoint_args("integer_gte", checkpoint) do
    case fetch_value(checkpoint, "min") do
      min when is_integer(min) -> {:ok, %{min: min}}
      _ -> {:error, "assert=integer_gte requires integer min"}
    end
  end

  defp normalize_checkpoint_args("contains", checkpoint) do
    if map_has_key?(checkpoint, "expected"),
      do: {:ok, %{expected: fetch_value(checkpoint, "expected")}},
      else: {:error, "assert=contains requires expected"}
  end

  defp normalize_checkpoint_args("length_equals", checkpoint) do
    case fetch_value(checkpoint, "expected") do
      n when is_integer(n) -> {:ok, %{expected: n}}
      _ -> {:error, "assert=length_equals requires integer expected"}
    end
  end

  defp normalize_checkpoint_args("type_is", checkpoint) do
    case fetch_value(checkpoint, "expected") do
      t when is_binary(t) and t != "" -> {:ok, %{expected: t}}
      _ -> {:error, "assert=type_is requires string expected"}
    end
  end

  defp normalize_checkpoint_args(_assertion, _checkpoint), do: {:ok, %{}}

  defp normalize_args(run) do
    case fetch_value(run, "args") do
      nil -> {:ok, []}
      args when is_list(args) -> {:ok, args}
      _ -> {:error, "execution.run.args must be an array"}
    end
  end

  defp normalize_timeout(run) do
    case fetch_value(run, "timeout_ms") do
      nil -> {:ok, @default_timeout_ms}
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, "execution.run.timeout_ms must be a positive integer"}
    end
  end

  defp validate_execution_type("module_call"), do: :ok
  defp validate_execution_type(type), do: {:error, "Unsupported execution type: #{inspect(type)}"}

  defp validate_assertion(assertion) when assertion in @assertions, do: :ok
  defp validate_assertion(assertion), do: {:error, "Unsupported assert: #{inspect(assertion)}"}

  # Map helpers — handle both string and atom keys from JSON

  defp fetch_non_empty(map, key) do
    case fetch_string(map, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, "#{key} is required"}
    end
  end

  defp fetch_string(map, key) do
    case fetch_value(map, key) do
      value when is_binary(value) -> String.trim(value)
      _ -> nil
    end
  end

  defp fetch_map(map, key) do
    case fetch_value(map, key) do
      value when is_map(value) -> value
      _ -> nil
    end
  end

  @doc false
  def fetch_value(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, safe_to_atom(key)))
  end

  defp map_has_key?(map, key) when is_map(map) do
    Map.has_key?(map, key) or Map.has_key?(map, safe_to_atom(key))
  end

  defp safe_to_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    _ -> nil
  end

  defp safe_to_atom(_), do: nil
end
