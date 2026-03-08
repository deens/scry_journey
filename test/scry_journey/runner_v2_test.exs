defmodule ScryJourney.RunnerV2Test do
  use ExUnit.Case, async: true

  alias ScryJourney.RunnerV2

  describe "run/2" do
    test "executes a simple passing script" do
      script = %{
        id: "simple",
        name: "Simple Test",
        timeout_ms: 5_000,
        steps: [
          %{
            id: "step_1",
            name: "First step",
            run: fn _ctx -> %{value: 42} end,
            checks: [
              %{id: "c1", path: "value", assert: "equals", expected: 42}
            ]
          }
        ]
      }

      report = RunnerV2.run(script)

      assert report.pass == true
      assert report.status == "PASS"
      assert report.id == "simple"
      assert report.schema_version == "journey_script/v2"
      assert report.step_counts.pass == 1
      assert report.check_counts.pass == 1
      assert report.duration_ms >= 0
    end

    test "threads context between steps" do
      script = %{
        id: "context_test",
        name: "Context Threading",
        timeout_ms: 5_000,
        steps: [
          %{
            id: "produce",
            name: "Produce value",
            run: fn _ctx -> %{x: 10} end,
            checks: []
          },
          %{
            id: "consume",
            name: "Consume value",
            run: fn ctx -> %{doubled: ctx.x * 2} end,
            checks: [
              %{id: "c1", path: "doubled", assert: "equals", expected: 20}
            ]
          }
        ]
      }

      report = RunnerV2.run(script)

      assert report.pass == true
      assert report.step_counts.pass == 2
      assert report.check_counts.pass == 1
    end

    test "checks can assert on data from prior steps" do
      script = %{
        id: "cross_step_check",
        name: "Cross-Step Checks",
        timeout_ms: 5_000,
        steps: [
          %{
            id: "s1",
            name: "Step 1",
            run: fn _ctx -> %{a: 1} end,
            checks: []
          },
          %{
            id: "s2",
            name: "Step 2",
            run: fn _ctx -> %{b: 2} end,
            checks: [
              %{id: "c_a", path: "a", assert: "equals", expected: 1},
              %{id: "c_b", path: "b", assert: "equals", expected: 2}
            ]
          }
        ]
      }

      report = RunnerV2.run(script)
      assert report.pass == true
      assert report.check_counts.pass == 2
    end

    test "skips remaining steps after failure" do
      script = %{
        id: "skip_test",
        name: "Skip Test",
        timeout_ms: 5_000,
        steps: [
          %{
            id: "s1",
            name: "Step 1",
            run: fn _ctx -> %{v: 1} end,
            checks: [
              %{id: "c1", path: "v", assert: "equals", expected: 99}
            ]
          },
          %{
            id: "s2",
            name: "Step 2 (should be skipped)",
            run: fn _ctx -> %{v: 2} end,
            checks: []
          }
        ]
      }

      report = RunnerV2.run(script)

      assert report.pass == false
      assert report.step_counts.fail == 1
      assert report.step_counts.skipped == 1
      assert length(report.steps) == 2

      [s1, s2] = report.steps
      assert s1.status == "FAIL"
      assert s2.status == "SKIPPED"
    end

    test "skips remaining steps after step error" do
      script = %{
        id: "error_test",
        name: "Error Test",
        timeout_ms: 5_000,
        steps: [
          %{
            id: "s1",
            name: "Step that crashes",
            run: fn _ctx -> raise "boom" end,
            checks: []
          },
          %{
            id: "s2",
            name: "Skipped",
            run: fn _ctx -> %{} end,
            checks: []
          }
        ]
      }

      report = RunnerV2.run(script)

      assert report.pass == false
      assert report.step_counts.error == 1
      assert report.step_counts.skipped == 1
    end

    test "runs teardown even after failure" do
      test_pid = self()

      script = %{
        id: "teardown_test",
        name: "Teardown Test",
        timeout_ms: 5_000,
        steps: [
          %{
            id: "s1",
            name: "Failing step",
            run: fn _ctx -> raise "fail" end,
            checks: []
          }
        ],
        teardown: fn _ctx ->
          send(test_pid, :teardown_ran)
        end
      }

      RunnerV2.run(script)

      assert_receive :teardown_ran, 1_000
    end

    test "teardown receives context from executed steps" do
      test_pid = self()

      script = %{
        id: "teardown_ctx",
        name: "Teardown Context",
        timeout_ms: 5_000,
        steps: [
          %{
            id: "s1",
            name: "Set value",
            run: fn _ctx -> %{game_pid: self()} end,
            checks: []
          }
        ],
        teardown: fn ctx ->
          send(test_pid, {:teardown_ctx, ctx})
        end
      }

      RunnerV2.run(script)

      assert_receive {:teardown_ctx, ctx}, 1_000
      assert is_pid(ctx.game_pid)
    end

    test "reports teardown error without crashing" do
      script = %{
        id: "teardown_error",
        name: "Teardown Error",
        timeout_ms: 5_000,
        steps: [
          %{
            id: "s1",
            name: "OK step",
            run: fn _ctx -> %{v: 1} end,
            checks: []
          }
        ],
        teardown: fn _ctx -> raise "teardown boom" end
      }

      report = RunnerV2.run(script)

      # Steps still pass, but teardown reports error
      assert report.pass == true
      assert report.teardown.status == "ERROR"
      assert report.teardown.error =~ "teardown boom"
    end

    test "handles step timeout" do
      script = %{
        id: "timeout_test",
        name: "Timeout Test",
        timeout_ms: 5_000,
        steps: [
          %{
            id: "s1",
            name: "Slow step",
            timeout_ms: 50,
            run: fn _ctx -> Process.sleep(:infinity) end,
            checks: []
          }
        ]
      }

      report = RunnerV2.run(script)

      assert report.pass == false
      [step] = report.steps
      assert step.status == "ERROR"
      assert step.error =~ "timed out"
    end

    test "handles script-level timeout" do
      script = %{
        id: "script_timeout",
        name: "Script Timeout",
        timeout_ms: 100,
        steps: [
          %{
            id: "s1",
            name: "Very slow step",
            timeout_ms: 30_000,
            run: fn _ctx -> Process.sleep(:infinity) end,
            checks: []
          }
        ]
      }

      report = RunnerV2.run(script)

      assert report.pass == false
      assert report.status == "ERROR"
      assert report.error =~ "timed out"
    end

    test "step with no checks passes" do
      script = %{
        id: "no_checks",
        name: "No Checks",
        timeout_ms: 5_000,
        steps: [
          %{
            id: "s1",
            name: "Step without checks",
            run: fn _ctx -> %{v: 1} end,
            checks: []
          }
        ]
      }

      report = RunnerV2.run(script)
      assert report.pass == true
      assert report.check_counts.pass == 0
    end

    test "no teardown is fine" do
      script = %{
        id: "no_teardown",
        name: "No Teardown",
        timeout_ms: 5_000,
        steps: [
          %{
            id: "s1",
            name: "Step",
            run: fn _ctx -> %{v: 1} end,
            checks: []
          }
        ]
      }

      report = RunnerV2.run(script)
      assert report.pass == true
      assert report.teardown == %{status: "OK"}
    end

    test "multi-step with all checks passing" do
      script = %{
        id: "full_flow",
        name: "Full Flow",
        timeout_ms: 5_000,
        steps: [
          %{
            id: "s1",
            name: "Create",
            run: fn _ctx -> %{id: 1, name: "test"} end,
            checks: [
              %{id: "c1", path: "id", assert: "present"},
              %{id: "c2", path: "name", assert: "non_empty_string"}
            ]
          },
          %{
            id: "s2",
            name: "Update",
            run: fn ctx -> %{updated_name: ctx.name <> "_updated"} end,
            checks: [
              %{id: "c3", path: "updated_name", assert: "contains", expected: "updated"}
            ]
          },
          %{
            id: "s3",
            name: "Verify",
            run: fn ctx -> %{final: ctx.id} end,
            checks: [
              %{id: "c4", path: "final", assert: "equals", expected: 1}
            ]
          }
        ]
      }

      report = RunnerV2.run(script)

      assert report.pass == true
      assert report.step_counts == %{pass: 3, fail: 0, skipped: 0, error: 0}
      assert report.check_counts == %{pass: 4, fail: 0}
    end
  end
end
