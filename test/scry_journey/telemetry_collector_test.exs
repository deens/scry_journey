defmodule ScryJourney.TelemetryCollectorTest do
  use ExUnit.Case, async: true

  alias ScryJourney.TelemetryCollector

  describe "capture/3" do
    test "captures telemetry events emitted during function execution" do
      event_name = [:scry_test, :telemetry_capture, :done]

      {result, telemetry} =
        TelemetryCollector.capture([event_name], fn ->
          :telemetry.execute(event_name, %{duration: 42}, %{source: "test"})
          {:ok, %{captured: true}}
        end)

      assert result == {:ok, %{captured: true}}
      assert telemetry.count == 1
      assert [event] = telemetry.events
      assert event.event == "scry_test.telemetry_capture.done"
      assert event.measurements.duration == 42
      assert event.metadata.source == "test"
    end

    test "captures multiple events" do
      event1 = [:scry_test, :multi, :first]
      event2 = [:scry_test, :multi, :second]

      {_result, telemetry} =
        TelemetryCollector.capture([event1, event2], fn ->
          :telemetry.execute(event1, %{n: 1}, %{})
          :telemetry.execute(event2, %{n: 2}, %{})
          :telemetry.execute(event1, %{n: 3}, %{})
          :ok
        end)

      assert telemetry.count == 3

      # Grouped by event name
      assert map_size(telemetry.by_event) == 2
      assert length(telemetry.by_event["scry_test.multi.first"]) == 2
      assert length(telemetry.by_event["scry_test.multi.second"]) == 1
    end

    test "returns empty result when no events emitted" do
      event_name = [:scry_test, :nothing, :happens]

      {result, telemetry} =
        TelemetryCollector.capture([event_name], fn ->
          %{x: 1}
        end)

      assert result == %{x: 1}
      assert telemetry.count == 0
      assert telemetry.events == []
    end

    test "detaches handlers even on exception" do
      event_name = [:scry_test, :exception, :test]

      assert_raise RuntimeError, fn ->
        TelemetryCollector.capture([event_name], fn ->
          raise "boom"
        end)
      end

      # Verify handler was detached by trying to emit — should not crash
      :telemetry.execute(event_name, %{}, %{})
    end

    test "does not capture events outside the function scope" do
      event_name = [:scry_test, :scope, :test]

      # Emit before capture
      :telemetry.execute(event_name, %{before: true}, %{})

      {_result, telemetry} =
        TelemetryCollector.capture([event_name], fn ->
          :telemetry.execute(event_name, %{during: true}, %{})
          :ok
        end)

      # Only the "during" event should be captured
      assert telemetry.count == 1
      assert hd(telemetry.events).measurements.during == true
    end

    test "handles non-serializable values in measurements and metadata" do
      event_name = [:scry_test, :safe, :values]

      {_result, telemetry} =
        TelemetryCollector.capture([event_name], fn ->
          :telemetry.execute(event_name, %{count: 5}, %{pid: self(), ref: make_ref()})
          :ok
        end)

      assert telemetry.count == 1
      event = hd(telemetry.events)
      assert event.measurements.count == 5
      # PID and ref should be inspected to strings
      assert is_binary(event.metadata.pid)
      assert is_binary(event.metadata.ref)
    end
  end

  describe "empty_result/0" do
    test "returns a properly structured empty result" do
      result = TelemetryCollector.empty_result()
      assert result.events == []
      assert result.count == 0
      assert result.by_event == %{}
    end
  end

  describe "RunnerV2 integration" do
    test "telemetry data is merged into step context" do
      event_name = [:scry_test, :runner_integration, :done]

      script = %{
        id: "telemetry_integration",
        name: "Telemetry Integration",
        steps: [
          %{
            id: "emit_step",
            name: "Step with telemetry",
            run: fn _ctx ->
              :telemetry.execute(event_name, %{value: 42}, %{source: "journey"})
              %{step_done: true}
            end,
            telemetry: [event_name],
            checks: [
              %{id: "has_telemetry", path: "telemetry.count", assert: "gte", expected: 1},
              %{id: "step_result", path: "step_done", assert: "truthy"}
            ]
          },
          %{
            id: "verify_step",
            name: "Verify telemetry in context",
            run: fn ctx ->
              # Previous step's telemetry should be in context
              %{prev_telemetry_count: ctx[:telemetry][:count] || 0}
            end,
            checks: [
              %{
                id: "prev_count",
                path: "prev_telemetry_count",
                assert: "gte",
                expected: 1
              }
            ]
          }
        ]
      }

      report = ScryJourney.RunnerV2.run(script)
      assert report.pass, "Expected pass, got: #{inspect(report, pretty: true, limit: :infinity)}"
      assert report.step_counts.pass == 2
    end

    test "steps without telemetry key work normally" do
      script = %{
        id: "no_telemetry",
        steps: [
          %{
            id: "normal",
            run: fn _ctx -> %{x: 1} end,
            checks: [%{id: "c1", path: "x", assert: "equals", expected: 1}]
          }
        ]
      }

      report = ScryJourney.RunnerV2.run(script)
      assert report.pass
    end
  end
end
