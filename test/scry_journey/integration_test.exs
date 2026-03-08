defmodule ScryJourney.IntegrationTest do
  use ExUnit.Case, async: true

  describe "health_check example" do
    test "runs the health check journey card end-to-end" do
      path = Path.join([File.cwd!(), "examples", "health_check.journey.json"])
      assert {:ok, report} = ScryJourney.verify(path)

      assert report.pass == true
      assert report.status == "PASS"
      assert report.card_id == "health_check"
      assert report.card_name == "Basic Health Check"
      assert report.checkpoint_counts.pass == 6
      assert report.checkpoint_counts.fail == 0

      # Verify the result contains expected system data
      assert is_integer(report.result.process_count)
      assert report.result.process_count > 0
      assert is_float(report.result.memory_mb)
      assert is_binary(report.result.elixir_version)
    end
  end
end
