defmodule ScryJourney.PrismQueryTest do
  use ExUnit.Case, async: true

  alias ScryJourney.PrismQuery

  # ──────────────────────────────────────────────
  # Test fixtures — simulate Prism snapshot structure
  # ──────────────────────────────────────────────

  defp snapshot_with_journey do
    %{
      nodes: [
        %{
          id: "journey:match_lifecycle",
          type: :journey,
          lane: :work,
          label: "Match Lifecycle",
          status: :online,
          meta: %{journey_id: "match_lifecycle", step_count: 3, source: "journey"}
        },
        %{
          id: "journey:match_lifecycle:create_match",
          type: :journey_step,
          lane: :work,
          label: "Create Match",
          status: :online,
          meta: %{
            journey_id: "match_lifecycle",
            step_id: "create_match",
            duration_ms: 12,
            source: "journey"
          }
        },
        %{
          id: "journey:match_lifecycle:join_players",
          type: :journey_step,
          lane: :work,
          label: "Join Players",
          status: :online,
          meta: %{
            journey_id: "match_lifecycle",
            step_id: "join_players",
            duration_ms: 8,
            source: "journey"
          }
        },
        %{
          id: "journey:match_lifecycle:play_tile",
          type: :journey_step,
          lane: :work,
          label: "Play Tile",
          status: :error,
          meta: %{
            journey_id: "match_lifecycle",
            step_id: "play_tile",
            duration_ms: 45,
            source: "journey"
          }
        },
        # Non-journey node
        %{
          id: "proc:Elixir.SomeServer",
          type: :process,
          lane: :app,
          label: "SomeServer",
          status: :online,
          meta: %{pid: "#PID<0.100.0>"}
        }
      ],
      edges: [
        %{
          id: "e1",
          from: "journey:match_lifecycle",
          to: "journey:match_lifecycle:create_match",
          type: "journey_flow",
          count: 1
        },
        %{
          id: "e2",
          from: "journey:match_lifecycle",
          to: "journey:match_lifecycle:join_players",
          type: "journey_flow",
          count: 1
        },
        %{
          id: "e3",
          from: "journey:match_lifecycle:create_match",
          to: "journey:match_lifecycle:join_players",
          type: "journey_flow",
          count: 1
        },
        %{
          id: "e4",
          from: "journey:match_lifecycle:join_players",
          to: "journey:match_lifecycle:play_tile",
          type: "journey_flow",
          count: 1
        },
        # Non-journey edge
        %{
          id: "e5",
          from: "proc:Elixir.SomeServer",
          to: "proc:Elixir.OtherServer",
          type: "message",
          count: 5
        }
      ],
      events: [
        %{
          id: "ev1",
          kind: "journey_started",
          trace_id: "journey:match_lifecycle",
          group: "journey"
        },
        %{id: "ev2", kind: "step_started", trace_id: "journey:match_lifecycle", group: "journey"},
        %{
          id: "ev3",
          kind: "step_completed",
          trace_id: "journey:match_lifecycle",
          group: "journey"
        },
        %{id: "ev4", kind: "process_info", trace_id: nil, group: "system"}
      ]
    }
  end

  defp empty_snapshot do
    %{nodes: [], edges: [], events: []}
  end

  # ──────────────────────────────────────────────
  # Node queries
  # ──────────────────────────────────────────────

  describe "find_node/2" do
    test "finds existing node by ID" do
      node = PrismQuery.find_node(snapshot_with_journey(), "journey:match_lifecycle")
      assert node.label == "Match Lifecycle"
      assert node.status == :online
    end

    test "returns nil for missing node" do
      assert PrismQuery.find_node(snapshot_with_journey(), "nonexistent") == nil
    end

    test "handles empty snapshot" do
      assert PrismQuery.find_node(empty_snapshot(), "anything") == nil
    end
  end

  describe "nodes_by_type/2" do
    test "filters journey nodes" do
      nodes = PrismQuery.nodes_by_type(snapshot_with_journey(), :journey)
      assert length(nodes) == 1
      assert hd(nodes).id == "journey:match_lifecycle"
    end

    test "filters journey_step nodes" do
      nodes = PrismQuery.nodes_by_type(snapshot_with_journey(), :journey_step)
      assert length(nodes) == 3
    end

    test "accepts string type" do
      nodes = PrismQuery.nodes_by_type(snapshot_with_journey(), "process")
      assert length(nodes) == 1
    end

    test "returns empty for nonexistent type" do
      assert PrismQuery.nodes_by_type(snapshot_with_journey(), :nonexistent) == []
    end
  end

  describe "nodes_by_meta/3" do
    test "filters by metadata key-value" do
      nodes = PrismQuery.nodes_by_meta(snapshot_with_journey(), :journey_id, "match_lifecycle")
      # 1 journey + 3 steps
      assert length(nodes) == 4
    end

    test "returns empty for unmatched value" do
      assert PrismQuery.nodes_by_meta(snapshot_with_journey(), :journey_id, "nonexistent") == []
    end
  end

  # ──────────────────────────────────────────────
  # Edge queries
  # ──────────────────────────────────────────────

  describe "edges_from/2" do
    test "finds edges originating from a node" do
      edges = PrismQuery.edges_from(snapshot_with_journey(), "journey:match_lifecycle")
      assert length(edges) == 2
    end

    test "returns empty for node with no outgoing edges" do
      assert PrismQuery.edges_from(snapshot_with_journey(), "journey:match_lifecycle:play_tile") ==
               []
    end
  end

  describe "edges_to/2" do
    test "finds edges pointing to a node" do
      edges = PrismQuery.edges_to(snapshot_with_journey(), "journey:match_lifecycle:join_players")
      # journey→join_players and create_match→join_players
      assert length(edges) == 2
    end
  end

  describe "edges_between/3" do
    test "finds edges between specific nodes" do
      edges =
        PrismQuery.edges_between(
          snapshot_with_journey(),
          "journey:match_lifecycle:create_match",
          "journey:match_lifecycle:join_players"
        )

      assert length(edges) == 1
      assert hd(edges).type == "journey_flow"
    end

    test "returns empty when no direct edge exists" do
      edges =
        PrismQuery.edges_between(
          snapshot_with_journey(),
          "journey:match_lifecycle:create_match",
          "journey:match_lifecycle:play_tile"
        )

      assert edges == []
    end
  end

  # ──────────────────────────────────────────────
  # Event queries
  # ──────────────────────────────────────────────

  describe "events_by_trace/2" do
    test "filters by trace_id" do
      events = PrismQuery.events_by_trace(snapshot_with_journey(), "journey:match_lifecycle")
      assert length(events) == 3
    end

    test "returns empty for unknown trace" do
      assert PrismQuery.events_by_trace(snapshot_with_journey(), "unknown") == []
    end
  end

  describe "events_by_group/2" do
    test "filters by group" do
      events = PrismQuery.events_by_group(snapshot_with_journey(), "journey")
      assert length(events) == 3
    end
  end

  # ──────────────────────────────────────────────
  # Journey-specific queries
  # ──────────────────────────────────────────────

  describe "journey_summary/2" do
    test "extracts complete journey summary" do
      summary = PrismQuery.journey_summary(snapshot_with_journey(), "match_lifecycle")

      assert summary.journey_id == "match_lifecycle"
      assert summary.node_id == "journey:match_lifecycle"
      assert summary.status == :online
      assert summary.label == "Match Lifecycle"
      assert summary.step_count == 3
      # create_match + join_players
      assert summary.steps_passed == 2
      # play_tile
      assert summary.steps_failed == 1
      # all journey_flow edges
      assert summary.edge_count == 4
      # events with matching trace_id
      assert summary.event_count == 3
    end

    test "includes per-step summaries" do
      summary = PrismQuery.journey_summary(snapshot_with_journey(), "match_lifecycle")

      step_ids = Enum.map(summary.steps, & &1.step_id)
      assert "create_match" in step_ids
      assert "join_players" in step_ids
      assert "play_tile" in step_ids

      failed_step = Enum.find(summary.steps, &(&1.step_id == "play_tile"))
      assert failed_step.status == :error
      assert failed_step.duration_ms == 45
    end

    test "returns nil for nonexistent journey" do
      assert PrismQuery.journey_summary(snapshot_with_journey(), "nonexistent") == nil
    end

    test "handles empty snapshot" do
      assert PrismQuery.journey_summary(empty_snapshot(), "anything") == nil
    end
  end

  describe "journey_health/3" do
    test "reports health for a passing journey" do
      # Modify snapshot to have all steps passing
      snapshot = %{
        nodes: [
          %{
            id: "journey:good",
            type: :journey,
            lane: :work,
            label: "Good",
            status: :online,
            meta: %{journey_id: "good", source: "journey"}
          },
          %{
            id: "journey:good:s1",
            type: :journey_step,
            lane: :work,
            label: "S1",
            status: :online,
            meta: %{journey_id: "good", step_id: "s1", source: "journey"}
          },
          %{
            id: "journey:good:s2",
            type: :journey_step,
            lane: :work,
            label: "S2",
            status: :online,
            meta: %{journey_id: "good", step_id: "s2", source: "journey"}
          }
        ],
        edges: [
          %{
            id: "e1",
            from: "journey:good",
            to: "journey:good:s1",
            type: "journey_flow",
            count: 1
          },
          %{
            id: "e2",
            from: "journey:good:s1",
            to: "journey:good:s2",
            type: "journey_flow",
            count: 1
          }
        ],
        events: []
      }

      health = PrismQuery.journey_health(snapshot, "good", 2)

      assert health.has_root == true
      assert health.has_all_steps == true
      assert health.all_steps_passed == true
      assert health.has_flow_edges == true
      assert health.complete == true
    end

    test "reports incomplete when steps are missing" do
      snapshot = %{
        nodes: [
          %{
            id: "journey:partial",
            type: :journey,
            lane: :work,
            label: "P",
            status: :online,
            meta: %{journey_id: "partial", source: "journey"}
          },
          %{
            id: "journey:partial:s1",
            type: :journey_step,
            lane: :work,
            label: "S1",
            status: :online,
            meta: %{journey_id: "partial", step_id: "s1", source: "journey"}
          }
        ],
        edges: [
          %{
            id: "e1",
            from: "journey:partial",
            to: "journey:partial:s1",
            type: "journey_flow",
            count: 1
          }
        ],
        events: []
      }

      health = PrismQuery.journey_health(snapshot, "partial", 3)

      assert health.has_root == true
      assert health.has_all_steps == false
      assert health.complete == false
    end

    test "reports failure when journey not found" do
      health = PrismQuery.journey_health(empty_snapshot(), "missing")

      assert health.has_root == false
      assert health.complete == false
      assert health.summary == nil
    end

    test "reports failure when steps have errors" do
      health = PrismQuery.journey_health(snapshot_with_journey(), "match_lifecycle", 3)

      assert health.has_root == true
      assert health.has_all_steps == true
      # play_tile has :error status
      assert health.all_steps_passed == false
      assert health.complete == false
    end
  end

  # ──────────────────────────────────────────────
  # Temporal queries
  # ──────────────────────────────────────────────

  defp temporal_snapshot do
    %{
      nodes: [],
      edges: [],
      events: [
        %{
          id: "e1",
          kind: "journey_started",
          at_ms: 1000,
          trace_id: "journey:t1",
          group: "journey",
          stage: "init",
          summary: "Started"
        },
        %{
          id: "e2",
          kind: "step_started",
          at_ms: 1010,
          trace_id: "journey:t1",
          group: "journey",
          stage: "step_start",
          summary: "Step A"
        },
        %{
          id: "e3",
          kind: "step_completed",
          at_ms: 1050,
          trace_id: "journey:t1",
          group: "journey",
          stage: "step_complete",
          summary: "Step A done"
        },
        %{
          id: "e4",
          kind: "step_started",
          at_ms: 1060,
          trace_id: "journey:t1",
          group: "journey",
          stage: "step_start",
          summary: "Step B"
        },
        %{
          id: "e5",
          kind: "step_completed",
          at_ms: 1200,
          trace_id: "journey:t1",
          group: "journey",
          stage: "step_complete",
          summary: "Step B done"
        },
        %{
          id: "e6",
          kind: "journey_completed",
          at_ms: 1210,
          trace_id: "journey:t1",
          group: "journey",
          stage: "complete",
          summary: "Done"
        },
        # Different trace
        %{id: "e7", kind: "other_event", at_ms: 1100, trace_id: "other", group: "system"}
      ]
    }
  end

  describe "event_sequence/2" do
    test "returns events in timestamp order" do
      seq = PrismQuery.event_sequence(temporal_snapshot(), "journey:t1")

      assert length(seq) == 6
      assert hd(seq).kind == "journey_started"
      assert List.last(seq).kind == "journey_completed"

      # Verify monotonic timestamps
      timestamps = Enum.map(seq, & &1.at_ms)
      assert timestamps == Enum.sort(timestamps)
    end

    test "returns empty for unknown trace" do
      assert PrismQuery.event_sequence(temporal_snapshot(), "unknown") == []
    end
  end

  describe "events_ordered?/3" do
    test "returns true for correct order" do
      assert PrismQuery.events_ordered?(temporal_snapshot(), "journey:t1", [
               "journey_started",
               "step_started",
               "step_completed",
               "journey_completed"
             ])
    end

    test "returns true for subsequence" do
      assert PrismQuery.events_ordered?(temporal_snapshot(), "journey:t1", [
               "journey_started",
               "journey_completed"
             ])
    end

    test "returns false for wrong order" do
      refute PrismQuery.events_ordered?(temporal_snapshot(), "journey:t1", [
               "journey_completed",
               "journey_started"
             ])
    end

    test "returns true for empty expected list" do
      assert PrismQuery.events_ordered?(temporal_snapshot(), "journey:t1", [])
    end

    test "returns false when expected event is missing" do
      refute PrismQuery.events_ordered?(temporal_snapshot(), "journey:t1", [
               "journey_started",
               "nonexistent_event"
             ])
    end
  end

  describe "events_within_ms?/3" do
    test "returns true when within window" do
      {result, span} = PrismQuery.events_within_ms?(temporal_snapshot(), "journey:t1", 500)
      assert result == true
      # 1210 - 1000
      assert span == 210
    end

    test "returns false when exceeding window" do
      {result, span} = PrismQuery.events_within_ms?(temporal_snapshot(), "journey:t1", 100)
      assert result == false
      assert span == 210
    end

    test "returns true for empty trace" do
      {result, span} = PrismQuery.events_within_ms?(temporal_snapshot(), "unknown", 10)
      assert result == true
      assert span == 0
    end
  end

  describe "journey_timing/2" do
    test "computes timing summary" do
      timing = PrismQuery.journey_timing(temporal_snapshot(), "t1")

      assert timing.total_ms == 210
      assert timing.event_count == 6
      assert timing.first_event == "journey_started"
      assert timing.last_event == "journey_completed"

      assert timing.sequence == [
               "journey_started",
               "step_started",
               "step_completed",
               "step_started",
               "step_completed",
               "journey_completed"
             ]
    end

    test "returns zeros for nonexistent journey" do
      timing = PrismQuery.journey_timing(empty_snapshot(), "nope")

      assert timing.total_ms == 0
      assert timing.event_count == 0
      assert timing.first_event == nil
      assert timing.last_event == nil
    end
  end

  # ──────────────────────────────────────────────
  # Process queries
  # ──────────────────────────────────────────────

  defp process_snapshot do
    %{
      nodes: [
        %{
          id: "sup:Dominoes.Runtime.MatchSupervisor",
          type: :supervisor,
          lane: :app,
          label: "Dominoes.Runtime.MatchSupervisor",
          status: :online,
          meta: %{application: "dominoes", pid: "#PID<0.500.0>"}
        },
        %{
          id: "worker:Dominoes.Runtime.MatchServer_abc",
          type: :worker,
          lane: :app,
          label: "MatchServer (abc)",
          status: :online,
          meta: %{
            application: "dominoes",
            pid: "#PID<0.501.0>",
            initial_call: "Dominoes.Runtime.MatchServer.init/1",
            registered_name: nil
          }
        },
        %{
          id: "sup:Phoenix.PubSub",
          type: :supervisor,
          lane: :app,
          label: "Phoenix.PubSub",
          status: :online,
          meta: %{application: "phoenix_pubsub", pid: "#PID<0.200.0>"}
        },
        %{
          id: "worker:Prism.Server",
          type: :worker,
          lane: :app,
          label: "Prism.Server",
          status: :online,
          meta: %{application: "prism", pid: "#PID<0.300.0>"}
        },
        # Journey node — should NOT match process queries
        %{
          id: "journey:test",
          type: :journey,
          lane: :work,
          label: "Test Journey",
          status: :online,
          meta: %{journey_id: "test"}
        }
      ],
      edges: [],
      events: []
    }
  end

  describe "find_process/2" do
    test "finds process by label substring" do
      procs = PrismQuery.find_process(process_snapshot(), "MatchServer")
      assert length(procs) == 1
      assert hd(procs).id == "worker:Dominoes.Runtime.MatchServer_abc"
    end

    test "finds process by initial_call" do
      procs = PrismQuery.find_process(process_snapshot(), "MatchServer.init")
      assert length(procs) == 1
    end

    test "case-insensitive matching" do
      procs = PrismQuery.find_process(process_snapshot(), "matchserver")
      assert length(procs) == 1
    end

    test "does not match journey nodes" do
      procs = PrismQuery.find_process(process_snapshot(), "Test Journey")
      assert procs == []
    end

    test "returns empty for no match" do
      assert PrismQuery.find_process(process_snapshot(), "NonExistent") == []
    end
  end

  describe "processes_for_app/2" do
    test "finds processes for an application" do
      procs = PrismQuery.processes_for_app(process_snapshot(), "dominoes")
      # supervisor + worker
      assert length(procs) == 2
    end

    test "accepts atom app name" do
      procs = PrismQuery.processes_for_app(process_snapshot(), :prism)
      assert length(procs) == 1
      assert hd(procs).label == "Prism.Server"
    end

    test "returns empty for unknown app" do
      assert PrismQuery.processes_for_app(process_snapshot(), "unknown") == []
    end
  end

  describe "app_health/2" do
    test "computes health summary" do
      health = PrismQuery.app_health(process_snapshot(), "dominoes")

      assert health.total == 2
      assert health.online == 2
      assert health.error == 0
      assert health.supervisors == 1
      assert health.workers == 1
    end

    test "returns zeros for unknown app" do
      health = PrismQuery.app_health(process_snapshot(), "unknown")

      assert health.total == 0
      assert health.online == 0
    end
  end
end
