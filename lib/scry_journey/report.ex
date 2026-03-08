defmodule ScryJourney.Report do
  @moduledoc """
  Build structured reports from journey execution results.
  """

  @doc "Build a report from a card, checkpoint results, and execution metadata."
  @spec build(map(), list(map()), map()) :: map()
  def build(card, checkpoint_results, meta \\ %{}) do
    pass_count = Enum.count(checkpoint_results, &(&1.status == "PASS"))
    fail_count = Enum.count(checkpoint_results, &(&1.status == "FAIL"))
    pass? = fail_count == 0

    %{
      card_id: card.id,
      card_name: card.name,
      schema_version: card.schema_version,
      pass: pass?,
      status: if(pass?, do: "PASS", else: "FAIL"),
      checkpoints: checkpoint_results,
      checkpoint_counts: %{pass: pass_count, fail: fail_count},
      transport: Map.get(meta, :transport, "local"),
      timeout_ms: Map.get(meta, :timeout_ms),
      result: Map.get(meta, :result)
    }
  end

  @doc "Build an error report when execution fails."
  @spec build_error(map(), term()) :: map()
  def build_error(card, reason) do
    %{
      card_id: card.id,
      card_name: card.name,
      schema_version: card.schema_version,
      pass: false,
      status: "ERROR",
      error: format_error(reason),
      checkpoints: [],
      checkpoint_counts: %{pass: 0, fail: 0},
      result: nil
    }
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
