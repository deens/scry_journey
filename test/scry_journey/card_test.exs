defmodule ScryJourney.CardTest do
  use ExUnit.Case, async: true

  alias ScryJourney.Card

  @valid_card %{
    "schema_version" => "journey_card/v1",
    "id" => "test_card",
    "name" => "Test Journey",
    "description" => "A test journey card",
    "execution" => %{
      "type" => "module_call",
      "run" => %{
        "module" => "Enum",
        "function" => "count",
        "args" => [[1, 2, 3]],
        "timeout_ms" => 5000
      }
    },
    "checkpoints" => [
      %{"id" => "count_check", "path" => "result", "assert" => "equals", "expected" => 3}
    ]
  }

  describe "normalize/1" do
    test "normalizes a valid card" do
      assert {:ok, card} = Card.normalize(@valid_card)
      assert card.id == "test_card"
      assert card.name == "Test Journey"
      assert card.description == "A test journey card"
      assert card.schema_version == "journey_card/v1"
      assert card.execution.type == "module_call"
      assert card.execution.run.module == "Enum"
      assert card.execution.run.function == "count"
      assert card.execution.run.args == [[1, 2, 3]]
      assert card.execution.run.timeout_ms == 5000
      assert length(card.checkpoints) == 1
      assert hd(card.checkpoints).id == "count_check"
    end

    test "rejects wrong schema version" do
      card = Map.put(@valid_card, "schema_version", "journey_card/v2")
      assert {:error, msg} = Card.normalize(card)
      assert msg =~ "schema_version"
    end

    test "rejects missing id" do
      card = Map.delete(@valid_card, "id")
      assert {:error, msg} = Card.normalize(card)
      assert msg =~ "id is required"
    end

    test "rejects missing name" do
      card = Map.delete(@valid_card, "name")
      assert {:error, msg} = Card.normalize(card)
      assert msg =~ "name is required"
    end

    test "rejects missing execution" do
      card = Map.delete(@valid_card, "execution")
      assert {:error, msg} = Card.normalize(card)
      assert msg =~ "execution"
    end

    test "rejects unsupported execution type" do
      card = put_in(@valid_card, ["execution", "type"], "unknown_type")
      assert {:error, msg} = Card.normalize(card)
      assert msg =~ "Unsupported execution type"
    end

    test "rejects empty checkpoints" do
      card = Map.put(@valid_card, "checkpoints", [])
      assert {:error, msg} = Card.normalize(card)
      assert msg =~ "checkpoints must not be empty"
    end

    test "rejects non-object input" do
      assert {:error, msg} = Card.normalize("not a map")
      assert msg =~ "JSON object"
    end

    test "defaults timeout_ms when not specified" do
      card = update_in(@valid_card, ["execution", "run"], &Map.delete(&1, "timeout_ms"))
      assert {:ok, normalized} = Card.normalize(card)
      assert normalized.execution.run.timeout_ms == Card.default_timeout_ms()
    end

    test "defaults args to empty list when not specified" do
      card = update_in(@valid_card, ["execution", "run"], &Map.delete(&1, "args"))
      assert {:ok, normalized} = Card.normalize(card)
      assert normalized.execution.run.args == []
    end
  end

  describe "normalize/1 checkpoint validation" do
    test "validates equals requires expected" do
      card =
        Map.put(@valid_card, "checkpoints", [
          %{"id" => "c1", "path" => "x", "assert" => "equals"}
        ])

      assert {:error, msg} = Card.normalize(card)
      assert msg =~ "expected"
    end

    test "validates one_of requires values" do
      card =
        Map.put(@valid_card, "checkpoints", [
          %{"id" => "c1", "path" => "x", "assert" => "one_of"}
        ])

      assert {:error, msg} = Card.normalize(card)
      assert msg =~ "values"
    end

    test "validates integer_gte requires min" do
      card =
        Map.put(@valid_card, "checkpoints", [
          %{"id" => "c1", "path" => "x", "assert" => "integer_gte"}
        ])

      assert {:error, msg} = Card.normalize(card)
      assert msg =~ "min"
    end

    test "validates unsupported assertion" do
      card =
        Map.put(@valid_card, "checkpoints", [
          %{"id" => "c1", "path" => "x", "assert" => "nonexistent"}
        ])

      assert {:error, msg} = Card.normalize(card)
      assert msg =~ "Unsupported assert"
    end

    test "normalizes all assertion types" do
      checkpoints = [
        %{"id" => "c1", "path" => "a", "assert" => "present"},
        %{"id" => "c2", "path" => "b", "assert" => "truthy"},
        %{"id" => "c3", "path" => "c", "assert" => "falsy"},
        %{"id" => "c4", "path" => "d", "assert" => "non_empty_string"},
        %{"id" => "c5", "path" => "e", "assert" => "equals", "expected" => 42},
        %{"id" => "c6", "path" => "f", "assert" => "one_of", "values" => [1, 2, 3]},
        %{"id" => "c7", "path" => "g", "assert" => "integer_gte", "min" => 10},
        %{"id" => "c8", "path" => "h", "assert" => "contains", "expected" => "foo"},
        %{"id" => "c9", "path" => "i", "assert" => "length_equals", "expected" => 3},
        %{"id" => "c10", "path" => "j", "assert" => "type_is", "expected" => "string"}
      ]

      card = Map.put(@valid_card, "checkpoints", checkpoints)
      assert {:ok, normalized} = Card.normalize(card)
      assert length(normalized.checkpoints) == 10
    end
  end

  describe "load/1" do
    setup do
      dir = System.tmp_dir!()
      path = Path.join(dir, "test_#{:erlang.unique_integer([:positive])}.journey.json")
      on_exit(fn -> File.rm(path) end)
      %{path: path}
    end

    test "loads a valid JSON file", %{path: path} do
      File.write!(path, Jason.encode!(@valid_card))
      assert {:ok, card} = Card.load(path)
      assert card.id == "test_card"
    end

    test "returns error for missing file" do
      assert {:error, :enoent} = Card.load("nonexistent.journey.json")
    end

    test "returns error for invalid JSON", %{path: path} do
      File.write!(path, "not json {{{")
      assert {:error, msg} = Card.load(path)
      assert msg =~ "Invalid JSON"
    end
  end
end
