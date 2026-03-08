defmodule ScryJourneyTest do
  use ExUnit.Case

  test "verify/1 returns error for missing file" do
    assert {:error, :enoent} = ScryJourney.verify("nonexistent.journey.json")
  end
end
