defmodule ScryJourney.PrismIntegrationTest do
  @moduledoc """
  Tests that Journey events flow through PubSub to Prism's graph model.

  These tests only run when Prism is available as a dependency.
  They verify the full data path: Journey → EventEmitter → PubSub → Server → Graph.
  """
  use ExUnit.Case, async: false

  # Skip if Prism is not loaded
  if Code.ensure_loaded?(Prism) do
    alias ScryJourney.EventEmitter

    describe "auto-detection" do
      test "prism_available?() returns true when Prism is loaded" do
        assert EventEmitter.prism_available?()
      end

      test "prism() returns a working emitter" do
        emitter = EventEmitter.prism()
        assert is_function(emitter, 2)
        # Should not crash when called
        assert :ok = emitter.(:test, %{journey_id: "test"})
      end
    end

    describe "event flow through Prism" do
      test "journey events arrive at Prism.Server and produce graph mutations" do
        # Subscribe to Prism snapshots so we can see the result
        Prism.subscribe()

        emitter = EventEmitter.prism()

        # Emit a journey lifecycle
        emitter.(:journey_started, %{
          journey_id: "integration_test",
          name: "Integration Test",
          step_count: 1,
          timestamp_ms: System.monotonic_time(:millisecond)
        })

        emitter.(:step_started, %{
          journey_id: "integration_test",
          step_id: "s1",
          step_name: "First Step",
          timestamp_ms: System.monotonic_time(:millisecond)
        })

        emitter.(:step_completed, %{
          journey_id: "integration_test",
          step_id: "s1",
          step_name: "First Step",
          status: "PASS",
          duration_ms: 5,
          check_count: 1,
          timestamp_ms: System.monotonic_time(:millisecond)
        })

        emitter.(:journey_completed, %{
          journey_id: "integration_test",
          pass: true,
          status: "PASS",
          duration_ms: 10,
          step_counts: %{pass: 1, fail: 0},
          check_counts: %{pass: 1, fail: 0},
          timestamp_ms: System.monotonic_time(:millisecond)
        })

        # Wait briefly for the Server to process events
        Process.sleep(50)

        # Force a snapshot refresh and check the graph state
        snapshot = Prism.snapshot()

        # Find journey nodes
        journey_nodes =
          Enum.filter(snapshot.nodes, fn n -> n.type == :journey or n.type == :journey_step end)

        assert length(journey_nodes) >= 2,
               "Expected journey + step nodes, got: #{inspect(Enum.map(journey_nodes, & &1.id))}"

        # Find the journey root node
        root = Enum.find(snapshot.nodes, fn n -> n.id == "journey:integration_test" end)
        assert root != nil, "Journey root node not found in snapshot"
        assert root.status == :online

        # Find the step node
        step = Enum.find(snapshot.nodes, fn n -> n.id == "journey:integration_test:s1" end)
        assert step != nil, "Step node not found in snapshot"
        assert step.status == :online

        # Find journey_flow edges
        flow_edges = Enum.filter(snapshot.edges, fn e -> e.type == "journey_flow" end)
        assert length(flow_edges) >= 1, "Expected journey_flow edges"

        # Find journey events in timeline
        journey_events = Enum.filter(snapshot.events, fn e -> e.group == "journey" end)

        assert length(journey_events) >= 4,
               "Expected 4+ journey events, got #{length(journey_events)}"

        # Verify trace_id grouping
        assert Enum.all?(journey_events, fn e ->
                 Map.get(e, :trace_id) == "journey:integration_test"
               end)
      end
    end

    describe "RunnerV2 with Prism emitter" do
      test "running a script with prism emitter produces graph nodes" do
        # Clean slate
        Prism.clear_live()
        Process.sleep(50)

        script = %{
          id: "prism_runner_test",
          name: "Prism Runner Test",
          steps: [
            %{
              id: "step_a",
              name: "Step A",
              run: fn _ctx -> %{x: 1} end,
              checks: [%{id: "c1", path: "x", assert: "equals", expected: 1}]
            },
            %{
              id: "step_b",
              name: "Step B",
              run: fn ctx -> %{y: ctx.x + 1} end,
              checks: [%{id: "c2", path: "y", assert: "equals", expected: 2}]
            }
          ]
        }

        emitter = EventEmitter.prism()
        report = ScryJourney.RunnerV2.run(script, emitter: emitter)
        assert report.pass

        # Wait for events to propagate
        Process.sleep(50)

        snapshot = Prism.snapshot()

        # Should have journey root + 2 step nodes
        journey_nodes =
          Enum.filter(snapshot.nodes, fn n ->
            n.type in [:journey, :journey_step] and
              String.starts_with?(n.id, "journey:prism_runner_test")
          end)

        assert length(journey_nodes) == 3,
               "Expected 3 journey nodes, got: #{inspect(Enum.map(journey_nodes, & &1.id))}"

        # Sequential edge: step_a → step_b
        step_edge =
          Enum.find(snapshot.edges, fn e ->
            e.from == "journey:prism_runner_test:step_a" and
              e.to == "journey:prism_runner_test:step_b"
          end)

        assert step_edge != nil, "Expected sequential step_a → step_b edge"
      end
    end
  else
    @tag :skip
    test "Prism integration tests skipped (Prism not available)" do
      :ok
    end
  end
end
