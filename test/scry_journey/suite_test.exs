defmodule ScryJourney.SuiteTest do
  use ExUnit.Case, async: true

  alias ScryJourney.Suite

  setup do
    dir = Path.join(System.tmp_dir!(), "suite_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp write_card(dir, filename, overrides \\ %{}) do
    card =
      Map.merge(
        %{
          "schema_version" => "journey_card/v1",
          "id" => Path.basename(filename, ".journey.json"),
          "name" => "Test #{Path.basename(filename, ".journey.json")}",
          "execution" => %{
            "type" => "module_call",
            "run" => %{
              "module" => "ScryJourney.SuiteTest.Helper",
              "function" => "healthy",
              "args" => []
            }
          },
          "checkpoints" => [
            %{"id" => "status", "path" => "status", "assert" => "equals", "expected" => "ok"}
          ]
        },
        overrides
      )

    path = Path.join(dir, filename)
    File.write!(path, Jason.encode!(card))
    path
  end

  describe "discover/1" do
    test "finds all journey files in directory", %{dir: dir} do
      write_card(dir, "a.journey.json")
      write_card(dir, "b.journey.json")
      File.write!(Path.join(dir, "not_a_journey.json"), "{}")

      paths = Suite.discover(dir)
      assert length(paths) == 2
      assert Enum.all?(paths, &String.ends_with?(&1, ".journey.json"))
    end

    test "returns empty list for empty directory", %{dir: dir} do
      assert Suite.discover(dir) == []
    end

    test "returns sorted paths", %{dir: dir} do
      write_card(dir, "z_last.journey.json")
      write_card(dir, "a_first.journey.json")

      paths = Suite.discover(dir)
      assert Path.basename(hd(paths)) == "a_first.journey.json"
    end
  end

  describe "run/2 with directory" do
    test "returns EMPTY for directory with no journeys", %{dir: dir} do
      report = Suite.run(dir)
      assert report.status == "EMPTY"
      assert report.summary.total == 0
    end

    test "runs all journeys and aggregates results", %{dir: dir} do
      write_card(dir, "passing.journey.json")

      report = Suite.run(dir)
      assert report.summary.total == 1
      assert report.directory == dir
    end
  end

  describe "run/2 with paths" do
    test "runs given paths and returns aggregate report", %{dir: dir} do
      path = write_card(dir, "test.journey.json")
      report = Suite.run([path])

      assert report.summary.total == 1
      assert length(report.results) == 1
    end

    test "handles load errors gracefully", %{dir: dir} do
      bad_path = Path.join(dir, "nonexistent.journey.json")
      report = Suite.run([bad_path])

      assert report.pass == false
      assert report.summary.errors == 1
      assert hd(report.results).status == "ERROR"
    end
  end
end

defmodule ScryJourney.SuiteTest.Helper do
  def healthy, do: %{status: "ok", uptime: 1000}
end
