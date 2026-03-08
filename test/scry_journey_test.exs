defmodule ScryJourneyTest do
  use ExUnit.Case, async: true

  describe "verify/1" do
    test "returns error for missing file" do
      assert {:error, :enoent} = ScryJourney.verify("nonexistent.journey.json")
    end

    test "loads and runs a valid journey card" do
      dir = System.tmp_dir!()

      path =
        Path.join(dir, "integration_test_#{:erlang.unique_integer([:positive])}.journey.json")

      card_json = %{
        "schema_version" => "journey_card/v1",
        "id" => "integration_test",
        "name" => "Integration Test",
        "execution" => %{
          "type" => "module_call",
          "run" => %{
            "module" => "Map",
            "function" => "new",
            "args" => [],
            "timeout_ms" => 5000
          }
        },
        "checkpoints" => [
          %{"id" => "result_type", "path" => "result", "assert" => "type_is", "expected" => "map"}
        ]
      }

      File.write!(path, Jason.encode!(card_json))
      on_exit(fn -> File.rm(path) end)

      assert {:ok, report} = ScryJourney.verify(path)
      assert report.card_id == "integration_test"
      assert is_boolean(report.pass)
    end
  end
end
