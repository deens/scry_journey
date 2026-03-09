defmodule ScryJourney.RecordingTest do
  use ExUnit.Case, async: true

  alias ScryJourney.{Recording, EventEmitter}

  @tmp_dir System.tmp_dir!()

  defp tmp_path(name) do
    Path.join([
      @tmp_dir,
      "scry_journey_test",
      "#{name}_#{System.unique_integer([:positive])}.etf"
    ])
  end

  describe "emitter/0 and save/2" do
    test "records and saves events to ETF file" do
      {emit, agent} = Recording.emitter()

      emit.(:journey_started, %{journey_id: "test", name: "Test"})
      emit.(:step_started, %{journey_id: "test", step_id: "s1"})
      emit.(:step_completed, %{journey_id: "test", step_id: "s1", status: "PASS"})
      emit.(:journey_completed, %{journey_id: "test", status: "PASS"})

      path = tmp_path("save_test")
      assert :ok = Recording.save(agent, path)
      assert File.exists?(path)

      # Clean up
      File.rm!(path)
    end

    test "saved recording can be loaded back" do
      {emit, agent} = Recording.emitter()

      emit.(:journey_started, %{journey_id: "roundtrip", name: "Roundtrip"})
      emit.(:step_completed, %{journey_id: "roundtrip", step_id: "s1", status: "PASS"})
      emit.(:journey_completed, %{journey_id: "roundtrip", status: "PASS"})

      path = tmp_path("roundtrip")
      Recording.save(agent, path)

      assert {:ok, recording} = Recording.load(path)
      assert recording.schema_version == "journey_recording/v1"
      assert recording.event_count == 3
      assert recording.journey_id == "roundtrip"
      assert length(recording.events) == 3

      # Events are in correct order
      [{:journey_started, _}, {:step_completed, _}, {:journey_completed, _}] = recording.events

      File.rm!(path)
    end
  end

  describe "save_events/2" do
    test "saves events directly without an agent" do
      events = [
        {:journey_started, %{journey_id: "direct"}},
        {:journey_completed, %{journey_id: "direct", status: "PASS"}}
      ]

      path = tmp_path("direct")
      assert :ok = Recording.save_events(events, path)

      {:ok, recording} = Recording.load(path)
      assert recording.event_count == 2

      File.rm!(path)
    end
  end

  describe "load/1" do
    test "returns error for non-existent file" do
      assert {:error, _} = Recording.load("/nonexistent/path.etf")
    end

    test "returns error for invalid schema" do
      path = tmp_path("bad_schema")
      File.mkdir_p!(Path.dirname(path))
      binary = :erlang.term_to_binary(%{schema_version: "unknown/v99", events: []})
      File.write!(path, binary)

      assert {:error, msg} = Recording.load(path)
      assert msg =~ "Unknown recording schema"

      File.rm!(path)
    end
  end

  describe "compare/2" do
    test "identical recordings produce :identical status" do
      events = [
        {:step_completed, %{step_id: "s1", status: "PASS", duration_ms: 10}},
        {:step_completed, %{step_id: "s2", status: "PASS", duration_ms: 20}}
      ]

      path_a = tmp_path("compare_a")
      path_b = tmp_path("compare_b")
      Recording.save_events(events, path_a)
      Recording.save_events(events, path_b)

      assert {:ok, diff} = Recording.compare(path_a, path_b)
      assert diff.status == :identical
      assert length(diff.step_diffs) == 2
      assert Enum.all?(diff.step_diffs, &(&1.change == :identical))

      File.rm!(path_a)
      File.rm!(path_b)
    end

    test "detects regression when step goes from PASS to FAIL" do
      events_a = [
        {:step_completed, %{step_id: "s1", status: "PASS", duration_ms: 10}}
      ]

      events_b = [
        {:step_completed, %{step_id: "s1", status: "FAIL", duration_ms: 15}}
      ]

      path_a = tmp_path("regression_a")
      path_b = tmp_path("regression_b")
      Recording.save_events(events_a, path_a)
      Recording.save_events(events_b, path_b)

      assert {:ok, diff} = Recording.compare(path_a, path_b)
      assert diff.status == :regression
      assert hd(diff.step_diffs).change == :regression

      File.rm!(path_a)
      File.rm!(path_b)
    end

    test "detects improvement when step goes from FAIL to PASS" do
      events_a = [
        {:step_completed, %{step_id: "s1", status: "FAIL", duration_ms: 10}}
      ]

      events_b = [
        {:step_completed, %{step_id: "s1", status: "PASS", duration_ms: 10}}
      ]

      path_a = tmp_path("improve_a")
      path_b = tmp_path("improve_b")
      Recording.save_events(events_a, path_a)
      Recording.save_events(events_b, path_b)

      assert {:ok, diff} = Recording.compare(path_a, path_b)
      assert diff.status == :improvement

      File.rm!(path_a)
      File.rm!(path_b)
    end

    test "detects timing changes" do
      events_a = [
        {:step_completed, %{step_id: "s1", status: "PASS", duration_ms: 100}}
      ]

      events_b = [
        {:step_completed, %{step_id: "s1", status: "PASS", duration_ms: 300}}
      ]

      path_a = tmp_path("timing_a")
      path_b = tmp_path("timing_b")
      Recording.save_events(events_a, path_a)
      Recording.save_events(events_b, path_b)

      assert {:ok, diff} = Recording.compare(path_a, path_b)
      assert length(diff.timing_changes) == 1
      assert hd(diff.timing_changes).change_pct == 200

      File.rm!(path_a)
      File.rm!(path_b)
    end
  end

  describe "end-to-end with RunnerV2" do
    test "record option captures full journey execution" do
      script = %{
        id: "e2e_record",
        name: "E2E Recording",
        steps: [
          %{
            id: "step_1",
            name: "First",
            run: fn _ctx -> %{x: 1} end,
            checks: [%{id: "c1", path: "x", assert: "equals", expected: 1}]
          },
          %{
            id: "step_2",
            name: "Second",
            run: fn ctx -> %{y: ctx.x + 1} end,
            checks: [%{id: "c2", path: "y", assert: "equals", expected: 2}]
          }
        ]
      }

      # Use emitter + recording together
      {rec_emit, agent} = Recording.emitter()
      collector_emit = EventEmitter.collector()
      combined = EventEmitter.combine([rec_emit, collector_emit])

      report = ScryJourney.RunnerV2.run(script, emitter: combined)
      assert report.pass

      path = tmp_path("e2e")
      Recording.save(agent, path)

      {:ok, recording} = Recording.load(path)
      assert recording.event_count > 0
      assert recording.journey_id == "e2e_record"

      # Verify events match collector
      collector_events = EventEmitter.collect()
      assert length(collector_events) == recording.event_count

      File.rm!(path)
    end
  end
end
