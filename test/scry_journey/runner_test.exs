defmodule ScryJourney.RunnerTest do
  use ExUnit.Case, async: true

  alias ScryJourney.Runner

  # A simple test module for execution
  defmodule TestModule do
    def passing_journey(_timeout) do
      %{user: %{id: 1, name: "Alice"}, status: "ok"}
    end

    def failing_journey(_timeout) do
      %{error: "something went wrong", status: "error"}
    end

    def slow_journey(sleep_ms) do
      Process.sleep(sleep_ms)
      %{done: true}
    end

    def crashing_journey(_) do
      raise "boom!"
    end
  end

  defp make_card(module_string, function, args, checkpoints) do
    %{
      schema_version: "journey_card/v1",
      id: "test",
      name: "Test Journey",
      description: nil,
      execution: %{
        type: "module_call",
        run: %{
          module: module_string,
          function: function,
          args: args,
          timeout_ms: 5000
        }
      },
      checkpoints: checkpoints
    }
  end

  describe "run/2 with local transport" do
    test "runs a passing journey" do
      card =
        make_card(
          "ScryJourney.RunnerTest.TestModule",
          "passing_journey",
          [5000],
          [
            %{id: "status", path: "status", assert: "equals", expected: "ok"},
            %{id: "user_present", path: "user.id", assert: "present"},
            %{id: "user_name", path: "user.name", assert: "non_empty_string"}
          ]
        )

      report = Runner.run(card, transport: :local)
      assert report.pass == true
      assert report.status == "PASS"
      assert report.checkpoint_counts.pass == 3
      assert report.checkpoint_counts.fail == 0
    end

    test "runs a failing journey" do
      card =
        make_card(
          "ScryJourney.RunnerTest.TestModule",
          "failing_journey",
          [5000],
          [
            %{id: "status", path: "status", assert: "equals", expected: "ok"}
          ]
        )

      report = Runner.run(card, transport: :local)
      assert report.pass == false
      assert report.status == "FAIL"
      assert report.checkpoint_counts.fail == 1
    end

    test "handles execution timeout" do
      card =
        make_card(
          "ScryJourney.RunnerTest.TestModule",
          "slow_journey",
          [10_000],
          [%{id: "done", path: "done", assert: "truthy"}]
        )

      report = Runner.run(card, transport: :local, timeout_ms: 100)
      assert report.pass == false
      assert report.status == "ERROR"
      assert report.error =~ "timed out"
    end

    test "handles execution crash" do
      card =
        make_card(
          "ScryJourney.RunnerTest.TestModule",
          "crashing_journey",
          [0],
          [%{id: "done", path: "done", assert: "truthy"}]
        )

      report = Runner.run(card, transport: :local)
      assert report.pass == false
      assert report.status == "ERROR"
      assert report.error =~ "boom!"
    end

    test "handles module not found" do
      card =
        make_card(
          "NonExistent.Module",
          "run",
          [],
          [%{id: "done", path: "done", assert: "truthy"}]
        )

      report = Runner.run(card, transport: :local)
      assert report.pass == false
      assert report.status == "ERROR"
      assert report.error =~ "Module not found"
    end

    test "report includes execution metadata" do
      card =
        make_card(
          "ScryJourney.RunnerTest.TestModule",
          "passing_journey",
          [5000],
          [%{id: "status", path: "status", assert: "present"}]
        )

      report = Runner.run(card, transport: :local)
      assert report.card_id == "test"
      assert report.card_name == "Test Journey"
      assert report.schema_version == "journey_card/v1"
      assert report.transport == "local"
      assert is_integer(report.timeout_ms)
      assert is_map(report.result)
    end

    test "uses card timeout_ms when opts don't specify" do
      card =
        make_card(
          "ScryJourney.RunnerTest.TestModule",
          "passing_journey",
          [5000],
          [%{id: "status", path: "status", assert: "present"}]
        )

      report = Runner.run(card, transport: :local)
      assert report.timeout_ms == 5000
    end

    test "opts timeout_ms overrides card timeout" do
      card =
        make_card(
          "ScryJourney.RunnerTest.TestModule",
          "passing_journey",
          [5000],
          [%{id: "status", path: "status", assert: "present"}]
        )

      report = Runner.run(card, transport: :local, timeout_ms: 10_000)
      assert report.timeout_ms == 10_000
    end
  end
end
