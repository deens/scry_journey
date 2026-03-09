defmodule ScryJourney.EventEmitterTest do
  use ExUnit.Case, async: true

  alias ScryJourney.EventEmitter

  describe "noop/0" do
    test "returns a function that does nothing" do
      emit = EventEmitter.noop()
      assert is_function(emit, 2)
      assert emit.(:test, %{}) == :ok
    end
  end

  describe "new/1" do
    test "wraps a custom function" do
      parent = self()
      emit = EventEmitter.new(fn type, payload -> send(parent, {type, payload}) end)
      emit.(:hello, %{data: 42})

      assert_receive {:hello, %{data: 42}}
    end
  end

  describe "collector/0 and collect/0" do
    test "collects events in emission order" do
      emit = EventEmitter.collector()
      emit.(:first, %{n: 1})
      emit.(:second, %{n: 2})
      emit.(:third, %{n: 3})

      events = EventEmitter.collect()
      assert length(events) == 3
      assert [{:first, %{n: 1}}, {:second, %{n: 2}}, {:third, %{n: 3}}] = events
    end

    test "collect returns empty list when no events" do
      assert EventEmitter.collect() == []
    end

    test "collector with explicit target pid" do
      parent = self()
      emit = EventEmitter.collector(parent)
      emit.(:test, %{x: 1})

      events = EventEmitter.collect()
      assert [{:test, %{x: 1}}] = events
    end
  end

  describe "combine/1" do
    test "sends events to all emitters" do
      parent = self()

      emit1 = fn type, payload -> send(parent, {:e1, type, payload}) end
      emit2 = fn type, payload -> send(parent, {:e2, type, payload}) end

      combined = EventEmitter.combine([emit1, emit2])
      combined.(:test, %{val: 1})

      assert_receive {:e1, :test, %{val: 1}}
      assert_receive {:e2, :test, %{val: 1}}
    end

    test "combining empty list produces noop" do
      combined = EventEmitter.combine([])
      assert combined.(:test, %{}) == :ok
    end
  end

  describe "event builders" do
    test "journey_started includes step count" do
      script = %{id: "test", name: "Test", steps: [%{}, %{}, %{}], timeout_ms: 10_000}
      event = EventEmitter.journey_started("test", script)

      assert event.journey_id == "test"
      assert event.name == "Test"
      assert event.step_count == 3
      assert event.timeout_ms == 10_000
      assert is_integer(event.timestamp_ms)
    end

    test "step_started includes step identity" do
      step = %{id: "s1", name: "Step One"}
      event = EventEmitter.step_started("j1", step)

      assert event.journey_id == "j1"
      assert event.step_id == "s1"
      assert event.step_name == "Step One"
    end

    test "step_completed includes status and duration" do
      step = %{id: "s1", name: "Step One"}
      report = %{status: "PASS", duration_ms: 42, checks: [%{}, %{}], error: nil}
      event = EventEmitter.step_completed("j1", step, report)

      assert event.status == "PASS"
      assert event.duration_ms == 42
      assert event.check_count == 2
      assert event.error == nil
    end

    test "checkpoint_evaluated includes assertion details" do
      step = %{id: "s1"}

      check = %{
        id: "c1",
        status: "PASS",
        path: "user.name",
        assert: "equals",
        message: "equals"
      }

      event = EventEmitter.checkpoint_evaluated("j1", step, check)

      assert event.check_id == "c1"
      assert event.status == "PASS"
      assert event.path == "user.name"
      assert event.assert == "equals"
    end

    test "journey_completed includes counts" do
      report = %{
        status: "PASS",
        pass: true,
        duration_ms: 100,
        step_counts: %{pass: 3, fail: 0, skipped: 0, error: 0},
        check_counts: %{pass: 5, fail: 0}
      }

      event = EventEmitter.journey_completed("j1", report)

      assert event.pass == true
      assert event.step_counts.pass == 3
      assert event.check_counts.pass == 5
    end

    test "teardown_completed handles success and error" do
      ok = EventEmitter.teardown_completed("j1", %{status: "OK", duration_ms: 5})
      assert ok.status == "OK"
      assert ok.error == nil

      err =
        EventEmitter.teardown_completed("j1", %{status: "ERROR", error: "boom", duration_ms: 3})

      assert err.status == "ERROR"
      assert err.error == "boom"
    end
  end

  describe "RunnerV2 integration" do
    test "emits full lifecycle events for a passing journey" do
      emit = EventEmitter.collector()

      script = %{
        id: "lifecycle_test",
        name: "Lifecycle Test",
        timeout_ms: 5_000,
        steps: [
          %{
            id: "step_1",
            name: "First Step",
            run: fn _ctx -> %{x: 1} end,
            checks: [
              %{id: "check_x", path: "x", assert: "equals", expected: 1}
            ]
          },
          %{
            id: "step_2",
            name: "Second Step",
            run: fn ctx -> %{y: ctx.x + 1} end,
            checks: [
              %{id: "check_y", path: "y", assert: "equals", expected: 2}
            ]
          }
        ]
      }

      report = ScryJourney.RunnerV2.run(script, emitter: emit)
      assert report.pass

      events = EventEmitter.collect()
      types = Enum.map(events, fn {type, _} -> type end)

      # Verify full lifecycle
      assert :journey_started in types
      assert :step_started in types
      assert :step_completed in types
      assert :checkpoint_evaluated in types
      assert :teardown_completed in types
      assert :journey_completed in types

      # Verify ordering: journey_started is first, journey_completed is last
      assert {:journey_started, _} = List.first(events)
      assert {:journey_completed, _} = List.last(events)

      # Verify we got events for both steps
      step_starts = Enum.filter(events, fn {t, _} -> t == :step_started end)
      assert length(step_starts) == 2

      # Verify checkpoint events
      checkpoints = Enum.filter(events, fn {t, _} -> t == :checkpoint_evaluated end)
      assert length(checkpoints) == 2
      assert Enum.all?(checkpoints, fn {_, p} -> p.status == "PASS" end)
    end

    test "emits events for failing journey" do
      emit = EventEmitter.collector()

      script = %{
        id: "fail_test",
        name: "Fail Test",
        steps: [
          %{
            id: "fail_step",
            name: "Will Fail",
            run: fn _ctx -> %{x: 99} end,
            checks: [
              %{id: "wrong", path: "x", assert: "equals", expected: 1}
            ]
          },
          %{
            id: "skipped_step",
            name: "Should Skip",
            run: fn _ctx -> %{y: 2} end
          }
        ]
      }

      report = ScryJourney.RunnerV2.run(script, emitter: emit)
      refute report.pass

      events = EventEmitter.collect()

      # Failed checkpoint event
      check_events = Enum.filter(events, fn {t, _} -> t == :checkpoint_evaluated end)
      assert length(check_events) == 1
      assert {_, %{status: "FAIL"}} = hd(check_events)

      # Only one step started (second was skipped)
      step_starts = Enum.filter(events, fn {t, _} -> t == :step_started end)
      assert length(step_starts) == 1

      # Journey completed with FAIL
      {_, completed} = List.last(events)
      assert completed.status == "FAIL"
      refute completed.pass
    end

    test "default noop emitter produces no events in mailbox" do
      script = %{
        id: "noop_test",
        steps: [%{id: "s1", run: fn _ctx -> %{ok: true} end}]
      }

      ScryJourney.RunnerV2.run(script)

      # No events should be in the mailbox
      assert EventEmitter.collect() == []
    end
  end
end
