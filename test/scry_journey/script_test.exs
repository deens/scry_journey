defmodule ScryJourney.ScriptTest do
  use ExUnit.Case, async: true

  alias ScryJourney.Script

  @fixtures_dir Path.join(__DIR__, "../fixtures/scripts")

  setup do
    File.mkdir_p!(@fixtures_dir)
    :ok
  end

  describe "load/1" do
    test "loads a valid journey script" do
      path =
        write_fixture("valid.journey.exs", """
        %{
          id: "test_journey",
          name: "Test Journey",
          steps: [
            %{
              id: "step_1",
              run: fn _ctx -> %{result: 42} end,
              checks: [
                %{id: "check_1", path: "result", assert: "equals", expected: 42}
              ]
            }
          ]
        }
        """)

      assert {:ok, script} = Script.load(path)
      assert script.id == "test_journey"
      assert script.name == "Test Journey"
      assert length(script.steps) == 1
      assert hd(script.steps).id == "step_1"
    end

    test "normalizes default values" do
      path =
        write_fixture("minimal.journey.exs", """
        %{
          steps: [
            %{run: fn _ctx -> %{ok: true} end}
          ]
        }
        """)

      assert {:ok, script} = Script.load(path)
      assert script.id == "minimal"
      assert script.timeout_ms == 30_000
      assert hd(script.steps).id == "step_1"
      assert hd(script.steps).checks == []
    end

    test "returns error for missing file" do
      assert {:error, {:file_not_found, _}} = Script.load("/nonexistent.journey.exs")
    end

    test "returns error for file that doesn't return a map" do
      path =
        write_fixture("bad_return.journey.exs", """
        [1, 2, 3]
        """)

      assert {:error, {:invalid_script, _}} = Script.load(path)
    end

    test "returns error for empty steps" do
      path =
        write_fixture("empty_steps.journey.exs", """
        %{steps: []}
        """)

      assert {:error, {:validation_error, msg}} = Script.load(path)
      assert msg =~ "steps must not be empty"
    end

    test "returns error for syntax error in script" do
      path =
        write_fixture("syntax_error.journey.exs", """
        %{steps: [%{run: fn ->
        """)

      assert {:error, {:load_error, _}} = Script.load(path)
    end

    test "normalizes atom assert values to strings" do
      path =
        write_fixture("atom_assert.journey.exs", """
        %{
          steps: [
            %{
              id: "s1",
              run: fn _ctx -> %{x: 1} end,
              checks: [%{id: "c1", path: "x", assert: :equals, expected: 1}]
            }
          ]
        }
        """)

      assert {:ok, script} = Script.load(path)
      check = hd(hd(script.steps).checks)
      assert check.assert == "equals"
    end
  end

  describe "from_inline/1" do
    test "builds script from inline arguments" do
      args = %{
        "id" => "inline_test",
        "steps" => [
          %{
            "id" => "s1",
            "code" => "%{x: 1 + 1}",
            "checks" => [
              %{"path" => "x", "assert" => "equals", "expected" => 2}
            ]
          }
        ]
      }

      assert {:ok, script} = Script.from_inline(args)
      assert script.id == "inline_test"
      assert length(script.steps) == 1
      step = hd(script.steps)
      assert step.code == "%{x: 1 + 1}"
      assert length(step.checks) == 1
    end

    test "handles await conditions" do
      args = %{
        "steps" => [
          %{
            "id" => "s1",
            "code" => "%{pid: self()}",
            "await" => %{
              "type" => "process_alive",
              "target" => "self"
            }
          }
        ]
      }

      assert {:ok, script} = Script.from_inline(args)
      step = hd(script.steps)
      assert step.await == {:process_alive, "self"}
    end

    test "handles teardown code" do
      args = %{
        "steps" => [%{"id" => "s1", "code" => ":ok"}],
        "teardown" => "GenServer.stop(pid)"
      }

      assert {:ok, script} = Script.from_inline(args)
      assert script.teardown == {:code, "GenServer.stop(pid)"}
    end

    test "returns error for empty steps" do
      assert {:error, {:validation_error, _}} = Script.from_inline(%{"steps" => []})
    end

    test "returns error for missing steps" do
      assert {:error, {:validation_error, _}} = Script.from_inline(%{})
    end
  end

  defp write_fixture(name, content) do
    path = Path.join(@fixtures_dir, name)
    File.write!(path, content)
    path
  end
end
