defmodule ScryJourney.StepTest do
  use ExUnit.Case, async: true

  alias ScryJourney.Step

  describe "execute/3 with function steps" do
    test "executes a function step and returns result" do
      step = %{run: fn _ctx -> %{value: 42} end}
      assert {:ok, %{value: 42}} = Step.execute(step, %{}, [])
    end

    test "passes context to the function" do
      step = %{run: fn ctx -> %{doubled: ctx.n * 2} end}
      assert {:ok, %{doubled: 10}} = Step.execute(step, %{n: 5}, [])
    end

    test "captures exceptions" do
      step = %{run: fn _ctx -> raise "boom" end}
      assert {:error, "boom"} = Step.execute(step, %{}, [])
    end

    test "handles timeout" do
      step = %{run: fn _ctx -> Process.sleep(:infinity) end}
      assert {:error, :timeout} = Step.execute(step, %{}, timeout_ms: 50)
    end

    test "respects step-level timeout_ms" do
      step = %{
        run: fn _ctx -> Process.sleep(:infinity) end,
        timeout_ms: 50
      }

      # Step timeout in opts takes precedence
      assert {:error, :timeout} = Step.execute(step, %{}, timeout_ms: 50)
    end

    test "handles non-map return values" do
      step = %{run: fn _ctx -> :ok end}
      assert {:ok, :ok} = Step.execute(step, %{}, [])
    end

    test "propagates {:error, reason} from step function" do
      step = %{run: fn _ctx -> {:error, "something failed"} end}
      assert {:error, "something failed"} = Step.execute(step, %{}, [])
    end
  end

  describe "execute/3 with invalid steps" do
    test "returns error for step with no run or code" do
      step = %{id: "bad_step"}
      assert {:error, msg} = Step.execute(step, %{}, [])
      assert msg =~ "no :run function"
    end
  end

  describe "await/3 with simple conditions" do
    test "process_alive succeeds for living process" do
      pid = spawn(fn -> Process.sleep(:infinity) end)

      result = Step.await({:process_alive, pid}, %{}, timeout_ms: 1_000)
      assert {:ok, _} = result

      Process.exit(pid, :kill)
    end

    test "process_dead succeeds for dead process" do
      pid = spawn(fn -> :ok end)
      Process.sleep(50)

      result = Step.await({:process_dead, pid}, %{}, timeout_ms: 1_000)
      assert {:ok, _} = result
    end

    test "times out when condition not met" do
      pid = spawn(fn -> Process.sleep(:infinity) end)

      result = Step.await({:process_dead, pid}, %{}, timeout_ms: 100)
      assert {:error, %{reason: :timeout}} = result

      Process.exit(pid, :kill)
    end
  end
end
