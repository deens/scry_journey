defmodule ScryJourney.PrismQuery do
  @moduledoc """
  Query helpers for Prism snapshot data.

  Works with the map structure returned by `Prism.snapshot()` to answer
  targeted questions about graph state. No compile-time dependency on Prism —
  operates purely on maps and lists.

  Used by `Observer` for enriched Prism capture, and available to journey
  steps that need to query the graph directly.

  ## Example

      snapshot = Prism.snapshot()
      summary = PrismQuery.journey_summary(snapshot, "match_lifecycle")
      # => %{status: :online, step_count: 3, steps_passed: 3, ...}
  """

  # ──────────────────────────────────────────────
  # Node queries
  # ──────────────────────────────────────────────

  @doc "Find a single node by ID. Returns nil if not found."
  @spec find_node(map(), String.t()) :: map() | nil
  def find_node(snapshot, node_id) do
    snapshot
    |> nodes()
    |> Enum.find(&(&1.id == node_id))
  end

  @doc "Filter nodes by type (atom or string)."
  @spec nodes_by_type(map(), atom() | String.t()) :: [map()]
  def nodes_by_type(snapshot, type) do
    type_str = to_string(type)

    snapshot
    |> nodes()
    |> Enum.filter(fn node ->
      to_string(node.type) == type_str
    end)
  end

  @doc "Filter nodes by a metadata key-value match."
  @spec nodes_by_meta(map(), atom() | String.t(), term()) :: [map()]
  def nodes_by_meta(snapshot, key, value) do
    snapshot
    |> nodes()
    |> Enum.filter(fn node ->
      meta = Map.get(node, :meta, %{})
      meta_get(meta, key) == value
    end)
  end

  # ──────────────────────────────────────────────
  # Edge queries
  # ──────────────────────────────────────────────

  @doc "Find all edges originating from a node."
  @spec edges_from(map(), String.t()) :: [map()]
  def edges_from(snapshot, node_id) do
    snapshot
    |> edges()
    |> Enum.filter(&(&1.from == node_id))
  end

  @doc "Find all edges pointing to a node."
  @spec edges_to(map(), String.t()) :: [map()]
  def edges_to(snapshot, node_id) do
    snapshot
    |> edges()
    |> Enum.filter(&(&1.to == node_id))
  end

  @doc "Find edges between two specific nodes."
  @spec edges_between(map(), String.t(), String.t()) :: [map()]
  def edges_between(snapshot, from_id, to_id) do
    snapshot
    |> edges()
    |> Enum.filter(&(&1.from == from_id and &1.to == to_id))
  end

  # ──────────────────────────────────────────────
  # Event queries
  # ──────────────────────────────────────────────

  @doc "Filter events by trace_id."
  @spec events_by_trace(map(), String.t()) :: [map()]
  def events_by_trace(snapshot, trace_id) do
    snapshot
    |> events()
    |> Enum.filter(&(&1[:trace_id] == trace_id))
  end

  @doc "Filter events by group."
  @spec events_by_group(map(), String.t()) :: [map()]
  def events_by_group(snapshot, group) do
    snapshot
    |> events()
    |> Enum.filter(&(&1[:group] == group))
  end

  # ──────────────────────────────────────────────
  # Journey-specific queries
  # ──────────────────────────────────────────────

  @doc """
  Extract a complete journey summary from a Prism snapshot.

  Returns a structured map with the journey's graph representation:
  root node status, step nodes with statuses, flow edges, and event count.

  Returns nil if the journey is not found in the snapshot.
  """
  @spec journey_summary(map(), String.t()) :: map() | nil
  def journey_summary(snapshot, journey_id) do
    journey_nid = "journey:#{normalize_id(journey_id)}"
    journey_node = find_node(snapshot, journey_nid)

    if journey_node do
      # Find all step nodes for this journey
      step_nodes =
        snapshot
        |> nodes_by_type(:journey_step)
        |> Enum.filter(fn node ->
          meta = Map.get(node, :meta, %{})
          meta_get(meta, :journey_id) == journey_id
        end)

      # Find flow edges from the journey
      flow_edges =
        snapshot
        |> edges()
        |> Enum.filter(fn edge ->
          edge.type == "journey_flow" and
            (String.starts_with?(edge.from, journey_nid) or
               String.starts_with?(edge.to, journey_nid))
        end)

      # Find journey events by trace
      trace_id = "journey:#{journey_id}"
      journey_events = events_by_trace(snapshot, trace_id)

      # Compute step status counts
      status_counts = count_step_statuses(step_nodes)

      %{
        journey_id: journey_id,
        node_id: journey_nid,
        status: journey_node.status,
        label: journey_node.label,
        step_count: length(step_nodes),
        steps_passed: Map.get(status_counts, :online, 0),
        steps_failed: Map.get(status_counts, :error, 0),
        steps_active: Map.get(status_counts, :active, 0),
        steps_idle: Map.get(status_counts, :idle, 0),
        edge_count: length(flow_edges),
        event_count: length(journey_events),
        steps: Enum.map(step_nodes, &step_summary/1),
        meta: Map.get(journey_node, :meta, %{})
      }
    end
  end

  @doc """
  Check whether a journey is fully represented in Prism's graph.

  Returns a map with boolean checks useful for assertions:

      %{
        has_root: true,
        has_all_steps: true,
        all_steps_passed: true,
        has_flow_edges: true,
        complete: true       # all of the above
      }
  """
  @spec journey_health(map(), String.t(), non_neg_integer()) :: map()
  def journey_health(snapshot, journey_id, expected_steps \\ 0) do
    summary = journey_summary(snapshot, journey_id)

    if summary do
      has_root = summary.status in [:online, :active]
      has_all_steps = expected_steps == 0 or summary.step_count == expected_steps
      all_passed = summary.steps_failed == 0 and summary.steps_active == 0
      has_edges = summary.edge_count > 0

      %{
        has_root: has_root,
        has_all_steps: has_all_steps,
        all_steps_passed: all_passed,
        has_flow_edges: has_edges,
        complete: has_root and has_all_steps and all_passed and has_edges,
        summary: summary
      }
    else
      %{
        has_root: false,
        has_all_steps: false,
        all_steps_passed: false,
        has_flow_edges: false,
        complete: false,
        summary: nil
      }
    end
  end

  # ──────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────

  defp nodes(%{nodes: nodes}) when is_list(nodes), do: nodes
  defp nodes(_), do: []

  defp edges(%{edges: edges}) when is_list(edges), do: edges
  defp edges(_), do: []

  defp events(%{events: events}) when is_list(events), do: events
  defp events(_), do: []

  defp step_summary(node) do
    meta = Map.get(node, :meta, %{})

    %{
      step_id: meta_get(meta, :step_id),
      node_id: node.id,
      status: node.status,
      label: node.label,
      duration_ms: meta_get(meta, :duration_ms)
    }
  end

  defp count_step_statuses(step_nodes) do
    Enum.reduce(step_nodes, %{}, fn node, acc ->
      status = node.status
      Map.update(acc, status, 1, &(&1 + 1))
    end)
  end

  # Access meta with atom or string key
  defp meta_get(meta, key) when is_atom(key) do
    Map.get(meta, key) || Map.get(meta, to_string(key))
  end

  defp meta_get(meta, key) when is_binary(key) do
    Map.get(meta, key) || Map.get(meta, safe_to_atom(key))
  end

  defp normalize_id(id) when is_binary(id), do: id
  defp normalize_id(id) when is_atom(id), do: Atom.to_string(id)
  defp normalize_id(id), do: to_string(id)

  defp safe_to_atom(str) do
    String.to_existing_atom(str)
  rescue
    _ -> nil
  end
end
