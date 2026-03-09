defmodule ScryJourney.Recording do
  @moduledoc """
  Capture and persist journey execution as an event stream.

  Recordings are stored as ETF (Erlang Term Format) files containing
  a map with metadata and a list of timestamped events. They can be
  loaded, compared, and replayed through Prism.

  ## Recording a Journey

      # Option 1: Auto-record with path
      report = ScryJourney.run_script(script, record: "recordings/payment.etf")

      # Option 2: Use the emitter directly
      {emitter, ref} = Recording.emitter()
      report = ScryJourney.RunnerV2.run(script, emitter: emitter)
      Recording.save(ref, "recordings/payment.etf")

  ## Comparing Runs

      diff = Recording.compare("recordings/v1.etf", "recordings/v2.etf")
      diff.status           # :identical | :regression | :improvement | :changed
      diff.step_diffs       # per-step comparison
      diff.timing_changes   # significant timing differences
  """

  alias ScryJourney.EventEmitter

  @schema_version "journey_recording/v1"

  @doc """
  Create a recording emitter and its reference.

  Returns `{emitter_fn, agent_pid}`. The agent accumulates events.
  Pass the agent to `save/2` when done.
  """
  @spec emitter() :: {EventEmitter.emitter(), pid()}
  def emitter do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    emit = fn type, payload ->
      Agent.update(agent, fn events -> [{type, payload} | events] end)
      :ok
    end

    {emit, agent}
  end

  @doc """
  Save a recording to disk.

  Takes the agent from `emitter/0` and writes it as ETF.
  Includes metadata: schema version, timestamp, event count.
  """
  @spec save(pid(), String.t()) :: :ok | {:error, term()}
  def save(agent, path) when is_pid(agent) and is_binary(path) do
    events = Agent.get(agent, fn events -> Enum.reverse(events) end)
    Agent.stop(agent)
    save_events(events, path)
  end

  @doc """
  Save a list of events directly to disk.
  """
  @spec save_events([{atom(), map()}], String.t()) :: :ok | {:error, term()}
  def save_events(events, path) when is_list(events) and is_binary(path) do
    recording = %{
      schema_version: @schema_version,
      recorded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      event_count: length(events),
      events: events,
      journey_id: extract_journey_id(events)
    }

    dir = Path.dirname(path)
    File.mkdir_p!(dir)

    binary = :erlang.term_to_binary(recording, [:compressed])
    File.write(path, binary)
  end

  @doc """
  Load a recording from disk.
  """
  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(path) do
    case File.read(path) do
      {:ok, binary} ->
        recording = :erlang.binary_to_term(binary)

        if recording[:schema_version] == @schema_version do
          {:ok, recording}
        else
          {:error, "Unknown recording schema: #{inspect(recording[:schema_version])}"}
        end

      {:error, reason} ->
        {:error, "Cannot read recording: #{reason}"}
    end
  end

  @doc """
  Compare two recordings and produce a diff report.

  Compares step outcomes, checkpoint results, and timing.
  Returns a structured diff with `:status` indicating the overall change.
  """
  @spec compare(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def compare(path_a, path_b) do
    with {:ok, a} <- load(path_a),
         {:ok, b} <- load(path_b) do
      {:ok, diff_recordings(a, b)}
    end
  end

  # -- Private --

  defp extract_journey_id([{_type, %{journey_id: id}} | _]), do: id
  defp extract_journey_id(_), do: nil

  defp diff_recordings(a, b) do
    a_steps = extract_steps(a.events)
    b_steps = extract_steps(b.events)

    step_diffs =
      zip_longest(a_steps, b_steps)
      |> Enum.map(fn
        {a_step, b_step} when not is_nil(a_step) and not is_nil(b_step) ->
          diff_step(a_step, b_step)

        {a_step, nil} ->
          %{step_id: a_step.step_id, change: :removed}

        {nil, b_step} ->
          %{step_id: b_step.step_id, change: :added}
      end)

    timing_changes = extract_timing_changes(a_steps, b_steps)

    # Determine overall status
    has_regression = Enum.any?(step_diffs, &(&1[:change] == :regression))
    has_improvement = Enum.any?(step_diffs, &(&1[:change] == :improvement))
    all_same = Enum.all?(step_diffs, &(&1[:change] == :identical))

    status =
      cond do
        all_same -> :identical
        has_regression -> :regression
        has_improvement -> :improvement
        true -> :changed
      end

    %{
      status: status,
      step_diffs: step_diffs,
      timing_changes: timing_changes,
      a_journey_id: a[:journey_id],
      b_journey_id: b[:journey_id],
      a_recorded_at: a[:recorded_at],
      b_recorded_at: b[:recorded_at]
    }
  end

  defp extract_steps(events) do
    events
    |> Enum.filter(fn {type, _} -> type == :step_completed end)
    |> Enum.map(fn {_, payload} -> payload end)
  end

  defp diff_step(a, b) do
    status_change =
      cond do
        a.status == b.status -> :identical
        a.status == "PASS" and b.status != "PASS" -> :regression
        a.status != "PASS" and b.status == "PASS" -> :improvement
        true -> :changed
      end

    timing_change =
      if a[:duration_ms] && b[:duration_ms] && a.duration_ms > 0 do
        ratio = b.duration_ms / max(a.duration_ms, 1)

        cond do
          ratio > 2.0 -> :slower
          ratio < 0.5 -> :faster
          true -> :stable
        end
      else
        :unknown
      end

    %{
      step_id: a.step_id || b.step_id,
      change: status_change,
      a_status: a.status,
      b_status: b.status,
      a_duration_ms: a[:duration_ms],
      b_duration_ms: b[:duration_ms],
      timing: timing_change
    }
  end

  defp extract_timing_changes(a_steps, b_steps) do
    Enum.zip(a_steps, b_steps)
    |> Enum.filter(fn {a, b} ->
      a[:duration_ms] && b[:duration_ms] && a.duration_ms > 0 &&
        abs(b.duration_ms - a.duration_ms) / max(a.duration_ms, 1) > 0.5
    end)
    |> Enum.map(fn {a, b} ->
      %{
        step_id: a.step_id,
        a_ms: a.duration_ms,
        b_ms: b.duration_ms,
        change_pct: round((b.duration_ms - a.duration_ms) / max(a.duration_ms, 1) * 100)
      }
    end)
  end

  # Polyfill for Enum.zip_longest (not in stdlib)
  defp zip_longest([], []), do: []
  defp zip_longest([a | as], [b | bs]), do: [{a, b} | zip_longest(as, bs)]
  defp zip_longest([a | as], []), do: [{a, nil} | zip_longest(as, [])]
  defp zip_longest([], [b | bs]), do: [{nil, b} | zip_longest([], bs)]
end
