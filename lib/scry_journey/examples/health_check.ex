defmodule ScryJourney.Examples.HealthCheck do
  @moduledoc """
  Example journey module that checks basic BEAM health.

  Used by the `health_check.journey.json` example card.
  """

  @doc "Gather system health metrics."
  def run do
    memory = :erlang.memory()

    %{
      process_count: length(Process.list()),
      memory_mb: Float.round(memory[:total] / 1_048_576, 2),
      otp_release: to_string(:erlang.system_info(:otp_release)),
      elixir_version: System.version(),
      schedulers: :erlang.system_info(:schedulers_online),
      node: to_string(Node.self()),
      uptime_seconds: div(:erlang.statistics(:wall_clock) |> elem(0), 1000)
    }
  end
end
