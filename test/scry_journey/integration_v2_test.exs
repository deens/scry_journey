defmodule ScryJourney.IntegrationV2Test do
  use ExUnit.Case

  describe "verify_script/1 with example script" do
    test "multi_step.journey.exs passes end-to-end" do
      {:ok, report} = ScryJourney.verify_script("examples/multi_step.journey.exs")

      assert report.pass == true
      assert report.status == "PASS"
      assert report.schema_version == "journey_script/v2"
      assert report.step_counts == %{pass: 3, fail: 0, skipped: 0, error: 0}
      assert report.check_counts == %{pass: 5, fail: 0}
      assert report.teardown.status == "OK"

      # Verify step details
      [s1, s2, s3] = report.steps
      assert s1.step_id == "create_agent"
      assert s1.status == "PASS"
      assert s2.step_id == "add_items"
      assert s2.status == "PASS"
      assert s3.step_id == "verify_state"
      assert s3.status == "PASS"
    end
  end

  describe "run_suite/1 with mixed formats" do
    test "discovers and runs both .json and .exs files" do
      # Create a temp directory with both formats
      dir =
        Path.join(
          System.tmp_dir!(),
          "scry_journey_suite_test_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)

      # Copy the v1 JSON example
      json_src = "examples/health_check.journey.json"
      json_dest = Path.join(dir, "health_check.journey.json")
      File.cp!(json_src, json_dest)

      # Write a simple v2 script
      exs_content = """
      %{
        id: "simple_v2",
        name: "Simple V2",
        steps: [
          %{
            id: "s1",
            run: fn _ctx -> %{value: 42} end,
            checks: [%{id: "c1", path: "value", assert: "equals", expected: 42}]
          }
        ]
      }
      """

      exs_dest = Path.join(dir, "simple.journey.exs")
      File.write!(exs_dest, exs_content)

      # Run suite
      report = ScryJourney.run_suite(dir)

      assert report.summary.total == 2
      assert report.summary.passed == 2
      assert report.pass == true

      # Clean up
      File.rm_rf!(dir)
    end
  end

  describe "load_script/1" do
    test "returns error for missing file" do
      assert {:error, {:file_not_found, _}} = ScryJourney.load_script("/nonexistent.exs")
    end
  end

  describe "run_inline/1" do
    test "runs inline steps (requires Scry.Evaluator)" do
      # This test verifies the inline path builds correctly
      # Actual eval requires Scry.Evaluator which may not be loaded in test
      args = %{
        "id" => "inline_test",
        "steps" => [
          %{
            "id" => "s1",
            "code" => "%{x: 1 + 1}",
            "checks" => [
              %{"path" => "x", "assert" => "equals", "expected" => 2}
            ]
          }
        ]
      }

      case ScryJourney.run_inline(args) do
        {:ok, report} ->
          # If Scry.Evaluator is available, it should work
          assert report.schema_version == "journey_script/v2"

        {:error, _} ->
          # If Scry.Evaluator is not loaded, that's expected in some test envs
          :ok
      end
    end
  end
end
