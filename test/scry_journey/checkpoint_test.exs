defmodule ScryJourney.CheckpointTest do
  use ExUnit.Case, async: true

  alias ScryJourney.Checkpoint

  describe "navigate_path/2" do
    test "navigates simple string keys" do
      data = %{"user" => %{"name" => "Alice"}}
      assert Checkpoint.navigate_path(data, "user.name") == "Alice"
    end

    test "navigates atom keys" do
      data = %{user: %{name: "Alice"}}
      assert Checkpoint.navigate_path(data, "user.name") == "Alice"
    end

    test "navigates list indices" do
      data = %{"items" => ["a", "b", "c"]}
      assert Checkpoint.navigate_path(data, "items.1") == "b"
    end

    test "navigates deeply nested paths" do
      data = %{"a" => %{"b" => %{"c" => %{"d" => 42}}}}
      assert Checkpoint.navigate_path(data, "a.b.c.d") == 42
    end

    test "returns nil for missing keys" do
      data = %{"user" => %{"name" => "Alice"}}
      assert Checkpoint.navigate_path(data, "user.email") == nil
    end

    test "returns nil for non-map input" do
      assert Checkpoint.navigate_path("not a map", "key") == nil
    end

    test "handles single-segment paths" do
      data = %{"status" => "ok"}
      assert Checkpoint.navigate_path(data, "status") == "ok"
    end
  end

  describe "evaluate/2 — equals" do
    test "passes when value equals expected" do
      checkpoint = %{id: "c1", path: "count", assert: "equals", expected: 3}
      result = %{count: 3}
      assert %{status: "PASS"} = Checkpoint.evaluate(checkpoint, result)
    end

    test "fails when value differs" do
      checkpoint = %{id: "c1", path: "count", assert: "equals", expected: 3}
      result = %{count: 5}
      assert %{status: "FAIL"} = Checkpoint.evaluate(checkpoint, result)
    end
  end

  describe "evaluate/2 — present" do
    test "passes when value exists" do
      checkpoint = %{id: "c1", path: "name", assert: "present"}
      result = %{name: "Alice"}
      assert %{status: "PASS"} = Checkpoint.evaluate(checkpoint, result)
    end

    test "fails when value is nil" do
      checkpoint = %{id: "c1", path: "name", assert: "present"}
      result = %{}
      assert %{status: "FAIL"} = Checkpoint.evaluate(checkpoint, result)
    end
  end

  describe "evaluate/2 — truthy" do
    test "passes for truthy values" do
      checkpoint = %{id: "c1", path: "ok", assert: "truthy"}
      assert %{status: "PASS"} = Checkpoint.evaluate(checkpoint, %{ok: true})
      assert %{status: "PASS"} = Checkpoint.evaluate(checkpoint, %{ok: "yes"})
      assert %{status: "PASS"} = Checkpoint.evaluate(checkpoint, %{ok: 1})
    end

    test "fails for nil and false" do
      checkpoint = %{id: "c1", path: "ok", assert: "truthy"}
      assert %{status: "FAIL"} = Checkpoint.evaluate(checkpoint, %{ok: nil})
      assert %{status: "FAIL"} = Checkpoint.evaluate(checkpoint, %{ok: false})
    end
  end

  describe "evaluate/2 — falsy" do
    test "passes for nil and false" do
      checkpoint = %{id: "c1", path: "ok", assert: "falsy"}
      assert %{status: "PASS"} = Checkpoint.evaluate(checkpoint, %{ok: nil})
      assert %{status: "PASS"} = Checkpoint.evaluate(checkpoint, %{ok: false})
    end

    test "fails for truthy values" do
      checkpoint = %{id: "c1", path: "ok", assert: "falsy"}
      assert %{status: "FAIL"} = Checkpoint.evaluate(checkpoint, %{ok: true})
    end
  end

  describe "evaluate/2 — non_empty_string" do
    test "passes for non-empty strings" do
      checkpoint = %{id: "c1", path: "val", assert: "non_empty_string"}
      assert %{status: "PASS"} = Checkpoint.evaluate(checkpoint, %{val: "hello"})
    end

    test "fails for empty string" do
      checkpoint = %{id: "c1", path: "val", assert: "non_empty_string"}
      assert %{status: "FAIL"} = Checkpoint.evaluate(checkpoint, %{val: ""})
    end

    test "fails for whitespace-only string" do
      checkpoint = %{id: "c1", path: "val", assert: "non_empty_string"}
      assert %{status: "FAIL"} = Checkpoint.evaluate(checkpoint, %{val: "   "})
    end

    test "fails for non-string" do
      checkpoint = %{id: "c1", path: "val", assert: "non_empty_string"}
      assert %{status: "FAIL"} = Checkpoint.evaluate(checkpoint, %{val: 42})
    end
  end

  describe "evaluate/2 — contains" do
    test "passes when string contains substring" do
      checkpoint = %{id: "c1", path: "msg", assert: "contains", expected: "world"}
      result = %{msg: "hello world"}
      assert %{status: "PASS"} = Checkpoint.evaluate(checkpoint, result)
    end

    test "passes when list contains element" do
      checkpoint = %{id: "c1", path: "tags", assert: "contains", expected: "elixir"}
      result = %{tags: ["erlang", "elixir", "beam"]}
      assert %{status: "PASS"} = Checkpoint.evaluate(checkpoint, result)
    end

    test "fails when not contained" do
      checkpoint = %{id: "c1", path: "msg", assert: "contains", expected: "xyz"}
      result = %{msg: "hello world"}
      assert %{status: "FAIL"} = Checkpoint.evaluate(checkpoint, result)
    end
  end

  describe "evaluate/2 — one_of" do
    test "passes when value is in list" do
      checkpoint = %{id: "c1", path: "status", assert: "one_of", values: ["ok", "pending"]}
      result = %{status: "ok"}
      assert %{status: "PASS"} = Checkpoint.evaluate(checkpoint, result)
    end

    test "fails when value is not in list" do
      checkpoint = %{id: "c1", path: "status", assert: "one_of", values: ["ok", "pending"]}
      result = %{status: "error"}
      assert %{status: "FAIL"} = Checkpoint.evaluate(checkpoint, result)
    end
  end

  describe "evaluate/2 — integer_gte" do
    test "passes when value >= min" do
      checkpoint = %{id: "c1", path: "count", assert: "integer_gte", min: 5}
      assert %{status: "PASS"} = Checkpoint.evaluate(checkpoint, %{count: 5})
      assert %{status: "PASS"} = Checkpoint.evaluate(checkpoint, %{count: 10})
    end

    test "fails when value < min" do
      checkpoint = %{id: "c1", path: "count", assert: "integer_gte", min: 5}
      assert %{status: "FAIL"} = Checkpoint.evaluate(checkpoint, %{count: 3})
    end

    test "fails for non-integer" do
      checkpoint = %{id: "c1", path: "count", assert: "integer_gte", min: 5}
      assert %{status: "FAIL"} = Checkpoint.evaluate(checkpoint, %{count: "not a number"})
    end
  end

  describe "evaluate/2 — length_equals" do
    test "passes when list length matches" do
      checkpoint = %{id: "c1", path: "items", assert: "length_equals", expected: 3}
      result = %{items: [1, 2, 3]}
      assert %{status: "PASS"} = Checkpoint.evaluate(checkpoint, result)
    end

    test "fails when list length differs" do
      checkpoint = %{id: "c1", path: "items", assert: "length_equals", expected: 3}
      result = %{items: [1, 2]}
      assert %{status: "FAIL"} = Checkpoint.evaluate(checkpoint, result)
    end

    test "fails for non-list" do
      checkpoint = %{id: "c1", path: "items", assert: "length_equals", expected: 3}
      result = %{items: "not a list"}
      assert %{status: "FAIL", message: msg} = Checkpoint.evaluate(checkpoint, result)
      assert msg =~ "expected list"
    end
  end

  describe "evaluate/2 — type_is" do
    test "matches string type" do
      checkpoint = %{id: "c1", path: "val", assert: "type_is", expected: "string"}
      assert %{status: "PASS"} = Checkpoint.evaluate(checkpoint, %{val: "hello"})
    end

    test "matches integer type" do
      checkpoint = %{id: "c1", path: "val", assert: "type_is", expected: "integer"}
      assert %{status: "PASS"} = Checkpoint.evaluate(checkpoint, %{val: 42})
    end

    test "matches boolean type" do
      checkpoint = %{id: "c1", path: "val", assert: "type_is", expected: "boolean"}
      assert %{status: "PASS"} = Checkpoint.evaluate(checkpoint, %{val: true})
    end

    test "matches map type" do
      checkpoint = %{id: "c1", path: "val", assert: "type_is", expected: "map"}
      assert %{status: "PASS"} = Checkpoint.evaluate(checkpoint, %{val: %{}})
    end

    test "matches list type" do
      checkpoint = %{id: "c1", path: "val", assert: "type_is", expected: "list"}
      assert %{status: "PASS"} = Checkpoint.evaluate(checkpoint, %{val: []})
    end

    test "fails on type mismatch" do
      checkpoint = %{id: "c1", path: "val", assert: "type_is", expected: "string"}
      assert %{status: "FAIL"} = Checkpoint.evaluate(checkpoint, %{val: 42})
    end
  end

  describe "evaluate/2 return structure" do
    test "includes all expected fields" do
      checkpoint = %{id: "test_id", path: "value", assert: "present"}
      result = Checkpoint.evaluate(checkpoint, %{value: 42})

      assert result.id == "test_id"
      assert result.path == "value"
      assert result.assert == "present"
      assert result.status == "PASS"
      assert result.actual == 42
      assert is_binary(result.message)
    end
  end
end
