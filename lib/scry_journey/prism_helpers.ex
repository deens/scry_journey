defmodule ScryJourney.PrismHelpers do
  @moduledoc """
  Convenience functions for Prism-aware journey steps.

  Wraps common PrismQuery patterns into single-call helpers that
  journey steps can use without manually calling `Prism.snapshot()`.

  All functions gracefully return defaults when Prism is not available.

  ## Usage in journey steps

      %{
        id: "check_graph",
        run: fn ctx ->
          import ScryJourney.PrismHelpers

          %{
            self_healthy: journey_complete?("my_journey", 3),
            app_ok: app_ok?("dominoes"),
            match_server: process_exists?("MatchServer"),
            ordered: events_in_order?("my_journey", ["step_started", "step_completed"])
          }
        end
      }
  """

  alias ScryJourney.PrismQuery

  # ──────────────────────────────────────────────
  # Snapshot access
  # ──────────────────────────────────────────────

  @doc "Get a fresh Prism snapshot, or empty map if Prism isn't available."
  @spec snapshot() :: map()
  def snapshot do
    if prism_available?() do
      apply(Prism, :snapshot, [])
    else
      %{nodes: [], edges: [], events: []}
    end
  end

  # ──────────────────────────────────────────────
  # Journey verification
  # ──────────────────────────────────────────────

  @doc "Check if a journey is complete and healthy in Prism's graph."
  @spec journey_complete?(String.t(), non_neg_integer()) :: boolean()
  def journey_complete?(journey_id, expected_steps \\ 0) do
    PrismQuery.journey_health(snapshot(), journey_id, expected_steps).complete
  end

  @doc "Get a journey summary from Prism's graph."
  @spec journey_info(String.t()) :: map() | nil
  def journey_info(journey_id) do
    PrismQuery.journey_summary(snapshot(), journey_id)
  end

  @doc "Get journey timing data."
  @spec journey_timing(String.t()) :: map()
  def journey_timing(journey_id) do
    PrismQuery.journey_timing(snapshot(), journey_id)
  end

  # ──────────────────────────────────────────────
  # Temporal checks
  # ──────────────────────────────────────────────

  @doc "Check that journey events appear in the expected order."
  @spec events_in_order?(String.t(), [String.t()]) :: boolean()
  def events_in_order?(journey_id, expected_kinds) do
    PrismQuery.events_ordered?(snapshot(), "journey:#{journey_id}", expected_kinds)
  end

  @doc "Check that all journey events occurred within a time window."
  @spec events_within?(String.t(), non_neg_integer()) :: boolean()
  def events_within?(journey_id, max_ms) do
    {within, _span} = PrismQuery.events_within_ms?(snapshot(), "journey:#{journey_id}", max_ms)
    within
  end

  # ──────────────────────────────────────────────
  # App-aware checks
  # ──────────────────────────────────────────────

  @doc "Check if a named process exists in Prism's graph."
  @spec process_exists?(String.t()) :: boolean()
  def process_exists?(name_pattern) do
    PrismQuery.find_process(snapshot(), name_pattern) != []
  end

  @doc "Check if all processes in an app are healthy (no errors)."
  @spec app_ok?(atom() | String.t()) :: boolean()
  def app_ok?(app) do
    health = PrismQuery.app_health(snapshot(), app)
    health.total > 0 and health.error == 0 and health.critical == 0
  end

  @doc "Get process count for an app."
  @spec app_process_count(atom() | String.t()) :: non_neg_integer()
  def app_process_count(app) do
    PrismQuery.app_health(snapshot(), app).total
  end

  # ──────────────────────────────────────────────
  # Graph queries
  # ──────────────────────────────────────────────

  @doc "Find a node by ID."
  @spec find_node(String.t()) :: map() | nil
  def find_node(node_id) do
    PrismQuery.find_node(snapshot(), node_id)
  end

  @doc "Count nodes of a given type."
  @spec count_nodes(atom() | String.t()) :: non_neg_integer()
  def count_nodes(type) do
    length(PrismQuery.nodes_by_type(snapshot(), type))
  end

  # ──────────────────────────────────────────────
  # Internal
  # ──────────────────────────────────────────────

  defp prism_available? do
    Code.ensure_loaded?(Prism) and function_exported?(Prism, :snapshot, 0)
  end
end
