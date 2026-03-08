defmodule ScryJourney.Runner do
  @moduledoc """
  Execute journey cards and evaluate checkpoints.

  Supports two execution transports:
  - `:local` — call the function directly via `apply/3`
  - `:scry` — call via Scry RPC to a remote node (requires optional scry dependency)
  """

  @doc "Run a journey card and return a report with checkpoint results."
  def run(card, opts \\ []) do
    # TODO: implement execution + checkpoint evaluation
    %{
      card_id: card["id"],
      card_name: card["name"],
      pass: false,
      status: "NOT_IMPLEMENTED",
      checkpoints: [],
      checkpoint_counts: %{pass: 0, fail: 0}
    }
  end
end
