defmodule ScryJourney.ContextTest do
  use ExUnit.Case, async: true

  alias ScryJourney.Context

  describe "new/0" do
    test "returns empty map" do
      assert Context.new() == %{}
    end
  end

  describe "merge/2" do
    test "merges map result into context" do
      ctx = %{a: 1}
      assert Context.merge(ctx, %{b: 2}) == %{a: 1, b: 2}
    end

    test "last-writer-wins on key collision" do
      ctx = %{a: 1, b: 2}
      assert Context.merge(ctx, %{b: 99}) == %{a: 1, b: 99}
    end

    test "unwraps {:ok, map} tuples" do
      ctx = %{a: 1}
      assert Context.merge(ctx, {:ok, %{b: 2}}) == %{a: 1, b: 2}
    end

    test "wraps non-map values under :result" do
      ctx = %{a: 1}
      assert Context.merge(ctx, 42) == %{a: 1, result: 42}
    end

    test "wraps nil under :result" do
      ctx = %{a: 1}
      assert Context.merge(ctx, nil) == %{a: 1, result: nil}
    end

    test "wraps lists under :result" do
      ctx = %{}
      assert Context.merge(ctx, [1, 2, 3]) == %{result: [1, 2, 3]}
    end

    test "merges into empty context" do
      assert Context.merge(%{}, %{x: 10}) == %{x: 10}
    end
  end

  describe "resolve_ref/2" do
    test "resolves atom key present in context" do
      ctx = %{game_pid: :some_pid}
      assert Context.resolve_ref(ctx, :game_pid) == :some_pid
    end

    test "passes through atom not in context (registered name)" do
      ctx = %{other: 1}
      assert Context.resolve_ref(ctx, :my_server) == :my_server
    end

    test "passes through non-atom values" do
      ctx = %{a: 1}
      pid = self()
      assert Context.resolve_ref(ctx, pid) == pid
      assert Context.resolve_ref(ctx, "string") == "string"
      assert Context.resolve_ref(ctx, 42) == 42
    end
  end

  describe "resolve_condition/2" do
    test "resolves process ref in process_state condition" do
      ctx = %{game_pid: self()}
      condition = {:process_state, :game_pid, ["status"], :equals, :playing}
      resolved = Context.resolve_condition(condition, ctx)
      assert resolved == {:process_state, self(), ["status"], :equals, :playing}
    end

    test "resolves process ref in process_alive condition" do
      ctx = %{worker: self()}
      condition = {:process_alive, :worker}
      resolved = Context.resolve_condition(condition, ctx)
      assert resolved == {:process_alive, self()}
    end

    test "resolves process ref in process_dead condition" do
      ctx = %{worker: self()}
      condition = {:process_dead, :worker}
      resolved = Context.resolve_condition(condition, ctx)
      assert resolved == {:process_dead, self()}
    end

    test "resolves table ref in ets_entry condition" do
      ctx = %{my_table: :actual_table}
      condition = {:ets_entry, :my_table, "key"}
      resolved = Context.resolve_condition(condition, ctx)
      assert resolved == {:ets_entry, :actual_table, "key"}
    end

    test "passes through eval conditions unchanged" do
      ctx = %{a: 1}
      condition = {:eval, "1 + 1 == 2"}
      resolved = Context.resolve_condition(condition, ctx)
      assert resolved == {:eval, "1 + 1 == 2"}
    end

    test "passes through atoms not in context" do
      ctx = %{other: 1}
      condition = {:process_alive, :my_registered_server}
      resolved = Context.resolve_condition(condition, ctx)
      assert resolved == {:process_alive, :my_registered_server}
    end
  end
end
