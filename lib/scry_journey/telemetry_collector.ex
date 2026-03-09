defmodule ScryJourney.TelemetryCollector do
  @moduledoc """
  Captures `:telemetry` events during journey step execution.

  Attaches temporary telemetry handlers around a step, then collects
  all matching events into a list for checkpoint assertions.

  ## Usage in Journey Scripts

      %{
        id: "create_order",
        run: fn ctx -> MyApp.Orders.create(%{item: "book"}) end,
        telemetry: [
          [:my_app, :repo, :query],
          [:phoenix, :router_dispatch, :stop]
        ],
        checks: [
          %{path: "telemetry.events", assert: "present"},
          %{path: "telemetry.count", assert: "gte", expected: 1}
        ]
      }

  The collector merges a `:telemetry` key into the step result with:
  - `events` — list of captured event maps (event_name, measurements, metadata, timestamp_ms)
  - `count` — total number of events captured
  - `by_event` — events grouped by event name string
  """

  @doc """
  Run a function while capturing telemetry events.

  Returns `{fun_result, telemetry_data}` where telemetry_data contains
  the captured events.

  ## Parameters

  - `event_prefixes` — list of telemetry event name prefixes to capture
  - `fun` — zero-arity function to execute while capturing
  - `opts` — optional configuration
    - `:timeout` — max capture duration in ms (default: 30_000)
  """
  @spec capture([list()], (-> term()), keyword()) :: {term(), map()}
  def capture(event_prefixes, fun, opts \\ [])
      when is_list(event_prefixes) and is_function(fun, 0) do
    if not Code.ensure_loaded?(:telemetry) do
      {fun.(), empty_result()}
    else
      collector = self()
      handler_id = "scry_journey_telemetry_#{System.unique_integer([:positive])}"
      ref = make_ref()

      # Attach handlers for all requested event prefixes
      handlers =
        Enum.with_index(event_prefixes)
        |> Enum.map(fn {prefix, idx} ->
          id = "#{handler_id}_#{idx}"
          handler_fn = build_handler(collector, ref)

          :telemetry.attach(id, prefix, handler_fn, %{})
          id
        end)

      # Run the function
      result =
        try do
          fun.()
        after
          # Always detach handlers, even on error
          Enum.each(handlers, fn id ->
            :telemetry.detach(id)
          end)
        end

      # Collect buffered events from mailbox
      timeout = Keyword.get(opts, :timeout, 50)
      events = drain_events(ref, timeout)

      telemetry_data = build_telemetry_data(events)
      {result, telemetry_data}
    end
  end

  @doc """
  Build an empty telemetry result (when no events captured or telemetry unavailable).
  """
  @spec empty_result() :: map()
  def empty_result do
    %{events: [], count: 0, by_event: %{}}
  end

  # -- Private --

  defp build_handler(collector, ref) do
    fn event_name, measurements, metadata, _config ->
      event = %{
        event: Enum.join(event_name, "."),
        event_name: event_name,
        measurements: safe_measurements(measurements),
        metadata: safe_metadata(metadata),
        timestamp_ms: System.monotonic_time(:millisecond)
      }

      send(collector, {:telemetry_event, ref, event})
    end
  end

  defp drain_events(ref, timeout) do
    drain_loop(ref, [], timeout)
  end

  defp drain_loop(ref, acc, timeout) do
    receive do
      {:telemetry_event, ^ref, event} ->
        drain_loop(ref, [event | acc], timeout)
    after
      timeout -> Enum.reverse(acc)
    end
  end

  defp build_telemetry_data(events) do
    by_event =
      Enum.group_by(events, & &1.event)

    %{
      events: events,
      count: length(events),
      by_event: by_event
    }
  end

  # Keep measurements simple — they're usually numbers
  defp safe_measurements(m) when is_map(m) do
    Map.new(m, fn {k, v} -> {k, safe_value(v)} end)
  end

  defp safe_measurements(_), do: %{}

  # Metadata can contain PIDs, refs, etc. — make it JSON-safe
  defp safe_metadata(m) when is_map(m) do
    Map.new(m, fn {k, v} -> {k, safe_value(v)} end)
  end

  defp safe_metadata(_), do: %{}

  defp safe_value(v) when is_number(v), do: v
  defp safe_value(v) when is_binary(v), do: v
  defp safe_value(v) when is_atom(v), do: v
  defp safe_value(v) when is_boolean(v), do: v
  defp safe_value(v) when is_list(v), do: Enum.map(v, &safe_value/1)

  defp safe_value(v) when is_map(v) do
    Map.new(v, fn {k, v2} -> {safe_value(k), safe_value(v2)} end)
  end

  defp safe_value(v), do: inspect(v, limit: 100)
end
