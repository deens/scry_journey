defmodule ScryJourney.Report do
  @moduledoc """
  Build structured reports from journey execution results.
  """

  @doc "Build a report from a card and list of checkpoint results."
  def build(card, checkpoint_results) do
    pass_count = Enum.count(checkpoint_results, & &1.pass)
    fail_count = length(checkpoint_results) - pass_count

    %{
      card_id: card["id"],
      card_name: card["name"],
      pass: fail_count == 0,
      status: if(fail_count == 0, do: "PASS", else: "FAIL"),
      checkpoints: checkpoint_results,
      checkpoint_counts: %{pass: pass_count, fail: fail_count}
    }
  end
end
