defmodule ScryJourney.Observer do
  @moduledoc """
  Captures runtime observations during journey step execution.

  Observer wraps step execution and captures what happened in the BEAM
  while the step was running — PubSub messages, Prism graph changes,
  process metrics. Results are merged into context under the `:observed`
  key so subsequent steps and checks can assert on runtime behavior.

  ## Step Configuration

      %{
        id: "play_tile",
        run: fn ctx -> ... end,

        # Observe PubSub messages during execution
        observe: [
          pubsub: {MyApp.PubSub, "match:*"},
          prism: true
        ],

        checks: [
          # Assert on observed PubSub messages
          %{id: "match_event", path: "observed.pubsub_count", assert: "gte", expected: 1},
          # Assert on Prism graph state
          %{id: "prism_nodes", path: "observed.prism.node_count", assert: "gte", expected: 3}
        ]
      }

  ## Observation Types

  - `:pubsub` — `{pubsub_mod, topic}` — subscribes to topic, collects messages during execution
  - `:prism` — `true` — snapshots Prism graph before/after, computes diff
  - `:processes` — `true` — captures process count and memory before/after
  """

  @doc """
  Wrap a function execution with runtime observation.

  Returns `{function_result, observations}` where observations is a map
  that gets merged into step context under `:observed`.
  """
  @spec capture(keyword(), (-> term())) :: {term(), map()}
  def capture(observe_opts, fun) when is_list(observe_opts) and is_function(fun, 0) do
    # Set up observers before execution
    pre = setup_observers(observe_opts)

    # Execute the function
    result = fun.()

    # Collect observations after execution
    observations = collect_observations(observe_opts, pre)

    {result, observations}
  end

  def capture(nil, fun), do: {fun.(), %{}}
  def capture(_, fun), do: {fun.(), %{}}

  @doc "Empty observation result."
  @spec empty_result() :: map()
  def empty_result, do: %{}

  # ──────────────────────────────────────────────
  # Setup — runs before the step function
  # ──────────────────────────────────────────────

  defp setup_observers(opts) do
    %{
      pubsub: setup_pubsub(Keyword.get(opts, :pubsub)),
      prism: setup_prism(Keyword.get(opts, :prism)),
      processes: setup_processes(Keyword.get(opts, :processes))
    }
  end

  # PubSub: subscribe to topic and collect messages
  defp setup_pubsub(nil), do: nil

  defp setup_pubsub({pubsub_mod, topic}) when is_atom(pubsub_mod) and is_binary(topic) do
    if Code.ensure_loaded?(Phoenix.PubSub) do
      # Subscribe to the topic
      apply(Phoenix.PubSub, :subscribe, [pubsub_mod, topic])
      %{pubsub_mod: pubsub_mod, topic: topic, subscribed_at: System.monotonic_time(:millisecond)}
    else
      nil
    end
  end

  defp setup_pubsub(_), do: nil

  # Prism: snapshot graph state before execution
  defp setup_prism(true) do
    if Code.ensure_loaded?(Prism) and function_exported?(Prism, :snapshot, 0) do
      snapshot = apply(Prism, :snapshot, [])

      %{
        before_node_count: length(Map.get(snapshot, :nodes, [])),
        before_edge_count: length(Map.get(snapshot, :edges, [])),
        before_event_count: length(Map.get(snapshot, :events, [])),
        before_node_ids: MapSet.new(Enum.map(snapshot.nodes, & &1.id))
      }
    else
      nil
    end
  end

  defp setup_prism(_), do: nil

  # Processes: capture count and memory
  defp setup_processes(true) do
    %{
      before_count: length(Process.list()),
      before_memory: :erlang.memory(:total)
    }
  end

  defp setup_processes(_), do: nil

  # ──────────────────────────────────────────────
  # Collection — runs after the step function
  # ──────────────────────────────────────────────

  defp collect_observations(opts, pre) do
    observations = %{}

    observations = collect_pubsub(observations, Keyword.get(opts, :pubsub), pre.pubsub)
    observations = collect_prism(observations, Keyword.get(opts, :prism), pre.prism)
    observations = collect_processes(observations, Keyword.get(opts, :processes), pre.processes)

    observations
  end

  # PubSub: drain mailbox of PubSub messages
  defp collect_pubsub(obs, nil, _pre), do: obs
  defp collect_pubsub(obs, _config, nil), do: obs

  defp collect_pubsub(obs, {pubsub_mod, topic}, _pre) do
    messages = drain_pubsub_messages()

    # Unsubscribe
    if Code.ensure_loaded?(Phoenix.PubSub) do
      apply(Phoenix.PubSub, :unsubscribe, [pubsub_mod, topic])
    end

    obs
    |> Map.put(:pubsub_messages, messages)
    |> Map.put(:pubsub_count, length(messages))
    |> Map.put(:pubsub_topic, topic)
  end

  # Prism: snapshot after and compute diff, with journey-aware enrichment
  defp collect_prism(obs, true, pre) when is_map(pre) do
    if Code.ensure_loaded?(Prism) and function_exported?(Prism, :snapshot, 0) do
      snapshot = apply(Prism, :snapshot, [])
      after_node_ids = MapSet.new(Enum.map(snapshot.nodes, & &1.id))

      new_node_ids = MapSet.difference(after_node_ids, pre.before_node_ids)

      prism_obs = %{
        node_count: length(snapshot.nodes),
        edge_count: length(snapshot.edges),
        event_count: length(snapshot.events),
        nodes_added: MapSet.size(new_node_ids),
        new_node_ids: MapSet.to_list(new_node_ids),
        node_delta: length(snapshot.nodes) - pre.before_node_count,
        edge_delta: length(snapshot.edges) - pre.before_edge_count,
        event_delta: length(snapshot.events) - pre.before_event_count
      }

      # Include diagnostics if available
      prism_obs =
        case Map.get(snapshot, :diagnostics) do
          %{summary: summary} -> Map.put(prism_obs, :diagnostics, summary)
          _ -> prism_obs
        end

      # Enrich with journey-specific graph data for new journey nodes
      prism_obs = enrich_with_journey_data(prism_obs, snapshot, new_node_ids)

      Map.put(obs, :prism, prism_obs)
    else
      obs
    end
  end

  defp collect_prism(obs, _, _), do: obs

  # Processes: capture after and compute delta
  defp collect_processes(obs, true, pre) when is_map(pre) do
    after_count = length(Process.list())
    after_memory = :erlang.memory(:total)

    Map.put(obs, :processes, %{
      count: after_count,
      count_delta: after_count - pre.before_count,
      memory_bytes: after_memory,
      memory_delta: after_memory - pre.before_memory
    })
  end

  defp collect_processes(obs, _, _), do: obs

  # ──────────────────────────────────────────────
  # Journey graph enrichment
  # ──────────────────────────────────────────────

  # Detect journey nodes among newly added nodes and attach summaries
  defp enrich_with_journey_data(prism_obs, snapshot, new_node_ids) do
    alias ScryJourney.PrismQuery

    # Find journey IDs from new nodes with "journey:" prefix
    journey_ids =
      new_node_ids
      |> MapSet.to_list()
      |> Enum.filter(&String.starts_with?(&1, "journey:"))
      |> Enum.map(&extract_journey_id/1)
      |> Enum.uniq()
      |> Enum.reject(&is_nil/1)

    case journey_ids do
      [] ->
        prism_obs

      ids ->
        journeys =
          Map.new(ids, fn id ->
            {id, PrismQuery.journey_summary(snapshot, id)}
          end)
          |> Enum.reject(fn {_, v} -> is_nil(v) end)
          |> Map.new()

        Map.put(prism_obs, :journeys, journeys)
    end
  end

  # Extract the base journey_id from a node_id like "journey:match_lifecycle:step1"
  defp extract_journey_id("journey:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [id | _] -> id
      _ -> nil
    end
  end

  defp extract_journey_id(_), do: nil

  # ──────────────────────────────────────────────
  # Helpers
  # ──────────────────────────────────────────────

  defp drain_pubsub_messages do
    drain_pubsub_messages([])
  end

  defp drain_pubsub_messages(acc) do
    receive do
      msg -> drain_pubsub_messages([safe_message(msg) | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp safe_message(msg) when is_tuple(msg) do
    # Convert to inspectable format — PubSub messages can contain non-serializable values
    msg
    |> Tuple.to_list()
    |> Enum.map(&safe_value/1)
  end

  defp safe_message(msg), do: safe_value(msg)

  defp safe_value(value) when is_pid(value), do: inspect(value)
  defp safe_value(value) when is_reference(value), do: inspect(value)
  defp safe_value(value) when is_port(value), do: inspect(value)
  defp safe_value(value) when is_function(value), do: inspect(value)

  defp safe_value(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {k, safe_value(v)} end)
  end

  defp safe_value(value) when is_list(value), do: Enum.map(value, &safe_value/1)

  defp safe_value(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&safe_value/1)

  defp safe_value(value), do: value
end
