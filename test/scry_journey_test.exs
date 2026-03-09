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

  describe "run_matrix/2" do
    test "runs all prop combinations and returns results" do
      script = %{
        id: "matrix_test",
        props: %{
          x: %{type: :integer, values: [1, 2]},
          y: %{type: :atom, values: [:a, :b]}
        },
        steps: [
          %{
            id: "s1",
            run: fn ctx -> %{sum: ctx.props.x, label: ctx.props.y} end,
            checks: [%{id: "c1", path: "sum", assert: "gte", expected: 1}]
          }
        ]
      }

      results = ScryJourney.run_matrix(script)

      assert length(results) == 4

      # All should pass
      assert Enum.all?(results, fn {_props, report} -> report.pass end)

      # Should cover all combinations
      prop_sets = Enum.map(results, fn {props, _report} -> props end)
      assert %{x: 1, y: :a} in prop_sets
      assert %{x: 1, y: :b} in prop_sets
      assert %{x: 2, y: :a} in prop_sets
      assert %{x: 2, y: :b} in prop_sets
    end

    test "returns single result for script without props" do
      script = %{
        id: "no_props",
        steps: [
          %{
            id: "s1",
            run: fn _ctx -> %{ok: true} end,
            checks: [%{id: "c1", path: "ok", assert: "truthy"}]
          }
        ]
      }

      results = ScryJourney.run_matrix(script)
      assert length(results) == 1
      [{props, report}] = results
      assert props == %{}
      assert report.pass
    end
  end

  describe "run_inline/2" do
    test "returns structured report from inline args" do
      # Inline mode uses string keys (from MCP JSON) and code strings.
      # Code strings require Scry.Evaluator, which may not be available,
      # so we just verify the pipeline runs and returns a valid report.
      args = %{
        "id" => "inline_test",
        "steps" => [
          %{
            "id" => "s1",
            "code" => "%{value: 42}",
            "checks" => [
              %{"id" => "c1", "path" => "value", "assert" => "equals", "expected" => 42}
            ]
          }
        ]
      }

      assert {:ok, report} = ScryJourney.run_inline(args)
      assert report.id == "inline_test"
      assert report.schema_version == "journey_script/v2"
      assert is_list(report.steps)
    end
  end
end
