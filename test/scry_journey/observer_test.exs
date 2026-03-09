defmodule ScryJourney.ObserverTest do
  use ExUnit.Case, async: true

  alias ScryJourney.Observer

  describe "capture/2 with no observers" do
    test "returns function result with empty observations" do
      {result, obs} = Observer.capture([], fn -> {:ok, %{x: 1}} end)
      assert result == {:ok, %{x: 1}}
      assert obs == %{}
    end

    test "handles nil observe opts" do
      {result, obs} = Observer.capture(nil, fn -> :done end)
      assert result == :done
      assert obs == %{}
    end
  end

  describe "capture/2 with process observer" do
    test "captures process count and memory" do
      {_result, obs} =
        Observer.capture([processes: true], fn ->
          # Spawn some processes to see a delta
          pids =
            for _ <- 1..5 do
              spawn(fn -> Process.sleep(500) end)
            end

          {:ok, pids}
        end)

      assert is_map(obs.processes)
      assert obs.processes.count > 0
      assert obs.processes.memory_bytes > 0
      # Delta might be positive (spawned processes) or zero (depends on timing)
      assert is_integer(obs.processes.count_delta)
      assert is_integer(obs.processes.memory_delta)
    end
  end

  describe "capture/2 with PubSub observer" do
    if Code.ensure_loaded?(Phoenix.PubSub) do
      test "captures PubSub messages during execution" do
        pubsub_name = ScryJourney.TestPubSub
        topic = "test:observer:#{System.unique_integer([:positive])}"

        start_supervised!({Phoenix.PubSub, name: pubsub_name})

        {_result, obs} =
          Observer.capture([pubsub: {pubsub_name, topic}], fn ->
            Phoenix.PubSub.broadcast(pubsub_name, topic, {:test_event, "hello"})
            Phoenix.PubSub.broadcast(pubsub_name, topic, {:test_event, "world"})
            Process.sleep(10)
            :ok
          end)

        assert obs.pubsub_count == 2
        assert obs.pubsub_topic == topic
        assert length(obs.pubsub_messages) == 2
      end

      test "returns empty when no messages are broadcast" do
        pubsub_name = ScryJourney.TestPubSub2
        topic = "test:observer:empty:#{System.unique_integer([:positive])}"

        start_supervised!({Phoenix.PubSub, name: pubsub_name})

        {_result, obs} =
          Observer.capture([pubsub: {pubsub_name, topic}], fn ->
            :ok
          end)

        assert obs.pubsub_count == 0
        assert obs.pubsub_messages == []
      end
    else
      test "PubSub tests skipped (Phoenix.PubSub not available)" do
        {_result, obs} =
          Observer.capture([pubsub: {SomeMod, "topic"}], fn -> :ok end)

        # Without PubSub, observation is empty
        assert obs == %{}
      end
    end
  end

  describe "RunnerV2 integration" do
    test "step with observe option captures runtime observations" do
      script = %{
        id: "observer_test",
        name: "Observer Test",
        steps: [
          %{
            id: "observed_step",
            name: "Step with process observation",
            run: fn _ctx ->
              # Do something observable
              pids = for _ <- 1..3, do: spawn(fn -> Process.sleep(200) end)
              %{spawned: length(pids)}
            end,
            observe: [processes: true],
            checks: [
              %{id: "spawned", path: "spawned", assert: "equals", expected: 3},
              %{id: "has_obs", path: "observed.processes.count", assert: "gte", expected: 1}
            ]
          },
          %{
            id: "verify_context",
            name: "Verify observations in context",
            run: fn ctx ->
              %{
                has_observed: is_map(ctx[:observed]),
                has_processes: is_map(ctx[:observed][:processes]),
                process_count: ctx[:observed][:processes][:count]
              }
            end,
            checks: [
              %{id: "obs_present", path: "has_observed", assert: "truthy"},
              %{id: "proc_present", path: "has_processes", assert: "truthy"},
              %{id: "proc_count", path: "process_count", assert: "gte", expected: 1}
            ]
          }
        ]
      }

      report = ScryJourney.RunnerV2.run(script)

      assert report.pass,
             "Expected pass, got: #{inspect(report, pretty: true, limit: :infinity)}"

      assert report.step_counts.pass == 2
    end

    test "step without observe works normally" do
      script = %{
        id: "no_observe",
        steps: [
          %{
            id: "normal",
            run: fn _ctx -> %{x: 42} end,
            checks: [%{id: "c1", path: "x", assert: "equals", expected: 42}]
          }
        ]
      }

      report = ScryJourney.RunnerV2.run(script)
      assert report.pass
    end
  end

  describe "empty_result/0" do
    test "returns empty map" do
      assert Observer.empty_result() == %{}
    end
  end
end
