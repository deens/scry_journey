defmodule ScryJourney.Checkpoint do
  @moduledoc """
  Checkpoint assertion evaluation.

  Evaluates a checkpoint against an execution result by navigating to
  the specified path and applying the assertion.

  ## Supported Assertions

  - `equals` — value equals expected
  - `not_equals` — value does not equal expected
  - `present` — value is not nil
  - `truthy` — value is not nil/false
  - `falsy` — value is nil or false
  - `contains` — string/list contains item
  - `one_of` — value is in allowed list
  - `integer_gte` — integer value >= min
  - `gte` — numeric value >= expected
  - `lte` — numeric value <= expected
  - `gt` — numeric value > expected
  - `lt` — numeric value < expected
  - `matches` — string matches regex pattern
  - `has_key` — map contains key
  - `non_empty_string` — non-empty binary
  - `length_equals` — collection length matches
  - `type_is` — value type matches string name
  """

  @doc "Evaluate a single checkpoint against a result map."
  @spec evaluate(map(), map()) :: map()
  def evaluate(checkpoint, result) when is_map(checkpoint) and is_map(result) do
    actual = navigate_path(result, checkpoint.path)

    {status, message} = apply_assertion(checkpoint.assert, checkpoint, actual)

    %{
      id: checkpoint.id,
      status: status,
      path: checkpoint.path,
      assert: checkpoint.assert,
      expected: checkpoint_expected(checkpoint),
      actual: actual,
      message: message
    }
  end

  @doc "Navigate a dot-separated path in a nested map/list."
  @spec navigate_path(term(), String.t()) :: term()
  def navigate_path(data, path) when is_map(data) and is_binary(path) do
    path
    |> String.split(".", trim: true)
    |> Enum.reduce_while(data, fn segment, current ->
      case next_value(current, segment) do
        :missing -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  def navigate_path(_data, _path), do: nil

  # Assertion implementations

  defp apply_assertion("equals", checkpoint, actual) do
    expected = Map.get(checkpoint, :expected)

    if actual == expected,
      do: {"PASS", "equals"},
      else: {"FAIL", "expected #{inspect(expected)}, got #{inspect(actual)}"}
  end

  defp apply_assertion("not_equals", checkpoint, actual) do
    expected = Map.get(checkpoint, :expected)

    if actual != expected,
      do: {"PASS", "not equals #{inspect(expected)}"},
      else: {"FAIL", "expected not #{inspect(expected)}, got #{inspect(actual)}"}
  end

  defp apply_assertion("gte", checkpoint, actual) do
    expected = Map.get(checkpoint, :expected)

    if is_number(actual) and actual >= expected,
      do: {"PASS", ">= #{expected}"},
      else: {"FAIL", "expected >= #{expected}, got #{inspect(actual)}"}
  end

  defp apply_assertion("lte", checkpoint, actual) do
    expected = Map.get(checkpoint, :expected)

    if is_number(actual) and actual <= expected,
      do: {"PASS", "<= #{expected}"},
      else: {"FAIL", "expected <= #{expected}, got #{inspect(actual)}"}
  end

  defp apply_assertion("gt", checkpoint, actual) do
    expected = Map.get(checkpoint, :expected)

    if is_number(actual) and actual > expected,
      do: {"PASS", "> #{expected}"},
      else: {"FAIL", "expected > #{expected}, got #{inspect(actual)}"}
  end

  defp apply_assertion("lt", checkpoint, actual) do
    expected = Map.get(checkpoint, :expected)

    if is_number(actual) and actual < expected,
      do: {"PASS", "< #{expected}"},
      else: {"FAIL", "expected < #{expected}, got #{inspect(actual)}"}
  end

  defp apply_assertion("matches", checkpoint, actual) do
    pattern = Map.get(checkpoint, :expected)

    case Regex.compile(pattern) do
      {:ok, regex} ->
        if is_binary(actual) and Regex.match?(regex, actual),
          do: {"PASS", "matches /#{pattern}/"},
          else: {"FAIL", "expected to match /#{pattern}/, got #{inspect(actual)}"}

      {:error, _} ->
        {"FAIL", "invalid regex pattern: #{pattern}"}
    end
  end

  defp apply_assertion("has_key", checkpoint, actual) do
    key = Map.get(checkpoint, :expected)

    cond do
      is_map(actual) and (Map.has_key?(actual, key) or Map.has_key?(actual, safe_to_atom(key))) ->
        {"PASS", "has key #{inspect(key)}"}

      is_map(actual) ->
        {"FAIL", "map missing key #{inspect(key)}"}

      true ->
        {"FAIL", "expected map with key #{inspect(key)}, got #{type_name(actual)}"}
    end
  end

  defp apply_assertion("present", _checkpoint, actual) do
    if is_nil(actual),
      do: {"FAIL", "expected value to be present"},
      else: {"PASS", "present"}
  end

  defp apply_assertion("truthy", _checkpoint, actual) do
    if actual not in [nil, false],
      do: {"PASS", "truthy"},
      else: {"FAIL", "expected truthy value"}
  end

  defp apply_assertion("falsy", _checkpoint, actual) do
    if actual in [nil, false],
      do: {"PASS", "falsy"},
      else: {"FAIL", "expected falsy value"}
  end

  defp apply_assertion("non_empty_string", _checkpoint, actual) do
    if is_binary(actual) and String.trim(actual) != "",
      do: {"PASS", "non-empty string"},
      else: {"FAIL", "expected non-empty string"}
  end

  defp apply_assertion("contains", checkpoint, actual) do
    expected = to_string(Map.get(checkpoint, :expected, ""))

    cond do
      is_binary(actual) and String.contains?(actual, expected) ->
        {"PASS", "contains matched"}

      is_list(actual) and expected in Enum.map(actual, &to_string/1) ->
        {"PASS", "contains matched"}

      true ->
        {"FAIL", "expected to contain #{inspect(expected)}"}
    end
  end

  defp apply_assertion("one_of", checkpoint, actual) do
    values = Map.get(checkpoint, :values, [])

    if actual in values,
      do: {"PASS", "one_of matched"},
      else: {"FAIL", "expected one of #{inspect(values)}, got #{inspect(actual)}"}
  end

  defp apply_assertion("integer_gte", checkpoint, actual) do
    min = Map.get(checkpoint, :min)

    if is_integer(actual) and is_integer(min) and actual >= min,
      do: {"PASS", "integer >= #{min}"},
      else: {"FAIL", "expected integer >= #{inspect(min)}, got #{inspect(actual)}"}
  end

  defp apply_assertion("length_equals", checkpoint, actual) do
    expected = Map.get(checkpoint, :expected)

    cond do
      is_list(actual) and length(actual) == expected ->
        {"PASS", "length equals #{expected}"}

      is_list(actual) ->
        {"FAIL", "expected length #{expected}, got #{length(actual)}"}

      is_nil(actual) ->
        {"FAIL", "expected list of length #{expected}, got nil"}

      true ->
        {"FAIL", "expected list, got #{type_name(actual)}"}
    end
  end

  defp apply_assertion("type_is", checkpoint, actual) do
    expected = to_string(Map.get(checkpoint, :expected))
    actual_type = type_name(actual)

    if actual_type == expected,
      do: {"PASS", "type is #{expected}"},
      else: {"FAIL", "expected type #{expected}, got #{actual_type}"}
  end

  # Path navigation helpers

  defp next_value(current, segment) when is_map(current) do
    cond do
      Map.has_key?(current, segment) -> Map.get(current, segment)
      Map.has_key?(current, safe_to_atom(segment)) -> Map.get(current, safe_to_atom(segment))
      true -> :missing
    end
  end

  defp next_value(current, segment) when is_list(current) do
    case Integer.parse(segment) do
      {index, ""} -> Enum.at(current, index) || :missing
      _ -> :missing
    end
  end

  defp next_value(_current, _segment), do: :missing

  defp safe_to_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    _ -> nil
  end

  defp checkpoint_expected(checkpoint) do
    cond do
      Map.has_key?(checkpoint, :expected) -> checkpoint.expected
      Map.has_key?(checkpoint, :values) -> checkpoint.values
      Map.has_key?(checkpoint, :min) -> checkpoint.min
      true -> nil
    end
  end

  defp type_name(nil), do: "nil"
  defp type_name(value) when is_binary(value), do: "string"
  defp type_name(value) when is_integer(value), do: "integer"
  defp type_name(value) when is_float(value), do: "float"
  defp type_name(true), do: "boolean"
  defp type_name(false), do: "boolean"
  defp type_name(value) when is_atom(value), do: "atom"
  defp type_name(value) when is_map(value), do: "map"
  defp type_name(value) when is_list(value), do: "list"
  defp type_name(_), do: "unknown"
end
