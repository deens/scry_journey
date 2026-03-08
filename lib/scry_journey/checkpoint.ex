defmodule ScryJourney.Checkpoint do
  @moduledoc """
  Checkpoint assertion evaluation.

  Supports these assertion types:
  - `equals` — value equals expected
  - `present` — value is not nil
  - `truthy` — value is not nil/false
  - `falsy` — value is nil or false
  - `contains` — string/list contains item
  - `one_of` — value is in allowed list
  - `integer_gte` — value >= min
  - `non_empty_string` — non-empty binary
  - `length_equals` — collection length matches
  - `type_is` — value type matches string name
  """

  @doc "Evaluate a single checkpoint against a result map."
  def evaluate(checkpoint, result) do
    # TODO: implement path navigation + assertion evaluation
    %{
      id: checkpoint["id"],
      status: "NOT_IMPLEMENTED",
      pass: false,
      actual: nil,
      expected: checkpoint["expected"]
    }
  end

  @doc "Navigate a dot-separated path in a nested map/list."
  def navigate_path(result, path) when is_binary(path) do
    path
    |> String.split(".")
    |> Enum.reduce(result, fn
      segment, acc when is_map(acc) ->
        Map.get(acc, segment) || Map.get(acc, String.to_existing_atom(segment))

      segment, acc when is_list(acc) ->
        case Integer.parse(segment) do
          {index, ""} -> Enum.at(acc, index)
          _ -> nil
        end

      _, _ ->
        nil
    end)
  end
end
