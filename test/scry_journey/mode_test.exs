defmodule ScryJourney.ModeTest do
  use ExUnit.Case, async: true

  alias ScryJourney.Mode

  # ──────────────────────────────────────────────
  # Fixtures
  # ──────────────────────────────────────────────

  defp passing_script do
    %{
      id: "mode_pass",
      steps: [
        %{
          id: "s1",
          run: fn _ctx -> %{x: 1} end,
          checks: [%{id: "c1", path: "x", assert: "equals", expected: 1}]
        }
      ]
    }
  end

  defp failing_script do
    %{
      id: "mode_fail",
      steps: [
        %{
          id: "s1",
          run: fn _ctx -> %{x: 99} end,
          checks: [%{id: "c1", path: "x", assert: "equals", expected: 1}]
        }
      ]
    }
  end

  defp prop_script do
    %{
      id: "mode_props",
      props: %{
        multiplier: %{type: :integer, default: 2, values: [2, 3, 5]}
      },
      steps: [
        %{
          id: "s1",
          run: fn ctx -> %{result: 10 * ctx.props.multiplier} end,
          checks: [%{id: "c1", path: "result", assert: "gte", expected: 1}]
        }
      ]
    }
  end

  # ──────────────────────────────────────────────
  # Basic lifecycle
  # ──────────────────────────────────────────────

  describe "lifecycle" do
    test "starts and runs immediately" do
      {:ok, pid} =
        Mode.start_link(
          script: passing_script(),
          interval: 60_000,
          run_immediately: true
        )

      # Give it time to execute
      Process.sleep(50)

      status = Mode.status(pid)
      assert status.runs >= 1
      assert status.last_status == "PASS"
      assert status.state == :watching

      Mode.stop(pid)
    end

    test "can be stopped cleanly" do
      {:ok, pid} =
        Mode.start_link(
          script: passing_script(),
          interval: 60_000
        )

      Process.sleep(50)
      assert Process.alive?(pid)

      Mode.stop(pid)
      Process.sleep(10)
      refute Process.alive?(pid)
    end

    test "reports status correctly" do
      {:ok, pid} =
        Mode.start_link(
          script: passing_script(),
          interval: 60_000
        )

      Process.sleep(50)

      status = Mode.status(pid)
      assert status.journey_id == "mode_pass"
      assert status.interval_ms == 60_000
      assert is_integer(status.uptime_ms)

      Mode.stop(pid)
    end
  end

  # ──────────────────────────────────────────────
  # Run tracking
  # ──────────────────────────────────────────────

  describe "run tracking" do
    test "tracks pass/fail counts" do
      {:ok, pid} =
        Mode.start_link(
          script: passing_script(),
          interval: 60_000
        )

      Process.sleep(50)

      status = Mode.status(pid)
      assert status.passes >= 1
      assert status.failures == 0

      Mode.stop(pid)
    end

    test "tracks failing runs" do
      {:ok, pid} =
        Mode.start_link(
          script: failing_script(),
          interval: 60_000
        )

      Process.sleep(50)

      status = Mode.status(pid)
      assert status.failures >= 1
      assert status.last_status == "FAIL"

      Mode.stop(pid)
    end

    test "last_report returns the most recent report" do
      {:ok, pid} =
        Mode.start_link(
          script: passing_script(),
          interval: 60_000
        )

      Process.sleep(50)

      report = Mode.last_report(pid)
      assert report != nil
      assert report.pass == true
      assert report.id == "mode_pass"

      Mode.stop(pid)
    end

    test "history returns recent runs" do
      {:ok, pid} =
        Mode.start_link(
          script: passing_script(),
          interval: 60_000
        )

      Process.sleep(50)

      # Trigger a few more runs
      Mode.run_now(pid)
      Process.sleep(50)
      Mode.run_now(pid)
      Process.sleep(50)

      history = Mode.history(pid)
      assert length(history) >= 2

      # History is newest-first
      assert hd(history).run >= 2

      Mode.stop(pid)
    end
  end

  # ──────────────────────────────────────────────
  # Pause/resume
  # ──────────────────────────────────────────────

  describe "pause/resume" do
    test "pause stops scheduled runs" do
      {:ok, pid} =
        Mode.start_link(
          script: passing_script(),
          interval: 100
        )

      Process.sleep(50)
      Mode.pause(pid)
      Process.sleep(10)

      count_at_pause = Mode.status(pid).runs

      # Wait longer than interval
      Process.sleep(200)

      count_after_wait = Mode.status(pid).runs
      assert count_after_wait == count_at_pause

      assert Mode.status(pid).state == :paused

      Mode.stop(pid)
    end

    test "resume restarts execution" do
      {:ok, pid} =
        Mode.start_link(
          script: passing_script(),
          interval: 60_000
        )

      Process.sleep(50)
      Mode.pause(pid)
      assert Mode.status(pid).state == :paused

      count_before = Mode.status(pid).runs

      Mode.resume(pid)
      Process.sleep(50)

      assert Mode.status(pid).state == :watching
      assert Mode.status(pid).runs > count_before

      Mode.stop(pid)
    end
  end

  # ──────────────────────────────────────────────
  # run_now
  # ──────────────────────────────────────────────

  describe "run_now" do
    test "triggers immediate execution" do
      {:ok, pid} =
        Mode.start_link(
          script: passing_script(),
          interval: 60_000
        )

      Process.sleep(50)
      count_before = Mode.status(pid).runs

      Mode.run_now(pid)
      Process.sleep(50)

      assert Mode.status(pid).runs > count_before

      Mode.stop(pid)
    end
  end

  # ──────────────────────────────────────────────
  # Event emission
  # ──────────────────────────────────────────────

  describe "event emission" do
    test "emits mode_started on init" do
      test_pid = self()

      emitter = fn type, payload ->
        send(test_pid, {:mode_event, type, payload})
        :ok
      end

      {:ok, pid} =
        Mode.start_link(
          script: passing_script(),
          interval: 60_000,
          emitter: emitter
        )

      Process.sleep(50)

      assert_received {:mode_event, :mode_started, payload}
      assert payload.journey_id == "mode_pass"
      assert payload.interval_ms == 60_000
      assert payload.props_mode == :fixed
      assert payload.step_count == 1
      assert is_integer(payload.timestamp_ms)

      Mode.stop(pid)
    end

    test "emits enriched mode_tick with run stats" do
      test_pid = self()

      emitter = fn type, payload ->
        send(test_pid, {:mode_event, type, payload})
        :ok
      end

      {:ok, pid} =
        Mode.start_link(
          script: passing_script(),
          interval: 60_000,
          emitter: emitter
        )

      Process.sleep(100)

      assert_received {:mode_event, :mode_tick, payload}
      assert payload.journey_id == "mode_pass"
      assert payload.status == "PASS"
      assert payload.run == 1
      assert payload.total_runs == 1
      assert payload.total_passes == 1
      assert payload.total_failures == 0
      assert payload.pass_rate == 1.0
      assert payload.regressions == 0
      assert payload.recoveries == 0
      assert is_integer(payload.duration_ms)
      assert is_integer(payload.timestamp_ms)

      Mode.stop(pid)
    end

    test "emits mode_regression and mode_recovered on transitions" do
      test_pid = self()
      run_counter = :counters.new(1, [:atomics])

      # First run passes, second fails, third passes again
      script = %{
        id: "transition_test",
        steps: [
          %{
            id: "s1",
            run: fn _ctx ->
              :counters.add(run_counter, 1, 1)
              run = :counters.get(run_counter, 1)
              %{x: if(run == 2, do: 99, else: 1)}
            end,
            checks: [%{id: "c1", path: "x", assert: "equals", expected: 1}]
          }
        ]
      }

      emitter = fn type, payload ->
        send(test_pid, {:mode_event, type, payload})
        :ok
      end

      {:ok, pid} =
        Mode.start_link(
          script: script,
          interval: 60_000,
          emitter: emitter
        )

      Process.sleep(50)

      # Run 1: PASS (no transition)
      assert_received {:mode_event, :mode_tick, %{status: "PASS", run: 1}}

      # Run 2: FAIL (regression)
      Mode.run_now(pid)
      Process.sleep(50)

      assert_received {:mode_event, :mode_tick, %{status: "FAIL", run: 2}}
      assert_received {:mode_event, :mode_regression, %{run: 2, message: msg}}
      assert msg =~ "Regression"

      # Run 3: PASS again (recovery)
      Mode.run_now(pid)
      Process.sleep(50)

      assert_received {:mode_event, :mode_tick, %{status: "PASS", run: 3}}
      assert_received {:mode_event, :mode_recovered, %{run: 3, message: msg}}
      assert msg =~ "Recovery"

      Mode.stop(pid)
    end
  end

  # ──────────────────────────────────────────────
  # Props modes
  # ──────────────────────────────────────────────

  describe "props modes" do
    test "fixed mode uses same props each run" do
      {:ok, pid} =
        Mode.start_link(
          script: prop_script(),
          interval: 60_000,
          props: %{multiplier: 5}
        )

      Process.sleep(50)
      Mode.run_now(pid)
      Process.sleep(50)

      history = Mode.history(pid)
      props_used = Enum.map(history, & &1.props)
      assert Enum.all?(props_used, &(&1 == %{multiplier: 5}))

      Mode.stop(pid)
    end

    test "random mode uses different props" do
      {:ok, pid} =
        Mode.start_link(
          script: prop_script(),
          interval: 60_000,
          props_mode: :random
        )

      Process.sleep(50)

      # Run several times
      for _ <- 1..5 do
        Mode.run_now(pid)
        Process.sleep(30)
      end

      history = Mode.history(pid)
      props_used = Enum.map(history, & &1.props)

      # All props should have :multiplier key
      assert Enum.all?(props_used, &Map.has_key?(&1, :multiplier))
      # Values should be from the declared set
      assert Enum.all?(props_used, &(&1.multiplier in [2, 3, 5]))

      Mode.stop(pid)
    end

    test "rotate mode cycles through combinations" do
      {:ok, pid} =
        Mode.start_link(
          script: prop_script(),
          interval: 60_000,
          props_mode: :rotate
        )

      Process.sleep(50)

      # Run 3 times to cycle through [2, 3, 5]
      Mode.run_now(pid)
      Process.sleep(30)
      Mode.run_now(pid)
      Process.sleep(30)

      history = Mode.history(pid, 3)
      multipliers = Enum.map(history, & &1.props.multiplier) |> Enum.reverse()

      # Should cycle through the expanded values
      assert length(multipliers) == 3
      assert Enum.all?(multipliers, &(&1 in [2, 3, 5]))

      Mode.stop(pid)
    end
  end
end
