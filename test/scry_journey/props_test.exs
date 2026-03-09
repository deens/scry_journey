defmodule ScryJourney.PropsTest do
  use ExUnit.Case, async: true

  alias ScryJourney.Props

  # ──────────────────────────────────────────────
  # Test fixtures
  # ──────────────────────────────────────────────

  defp script_with_props do
    %{
      id: "test_props",
      props: %{
        player_count: %{type: :integer, default: 2, range: 2..6},
        ruleset: %{type: :atom, default: :draw, values: [:draw, :block, :all_fives]},
        verbose: %{type: :boolean, default: false}
      },
      steps: []
    }
  end

  defp script_no_props do
    %{id: "no_props", steps: []}
  end

  # ──────────────────────────────────────────────
  # resolve/2
  # ──────────────────────────────────────────────

  describe "resolve/2" do
    test "returns defaults when no overrides" do
      {:ok, props} = Props.resolve(script_with_props())
      assert props.player_count == 2
      assert props.ruleset == :draw
      assert props.verbose == false
    end

    test "merges overrides with defaults" do
      {:ok, props} = Props.resolve(script_with_props(), %{player_count: 4})
      assert props.player_count == 4
      assert props.ruleset == :draw
    end

    test "validates type constraints" do
      {:error, msg} = Props.resolve(script_with_props(), %{player_count: "not_int"})
      assert msg =~ "player_count"
      assert msg =~ "integer"
    end

    test "validates range constraints" do
      {:error, msg} = Props.resolve(script_with_props(), %{player_count: 10})
      assert msg =~ "player_count"
      assert msg =~ "not in"
    end

    test "validates values constraints" do
      {:error, msg} = Props.resolve(script_with_props(), %{ruleset: :muggins})
      assert msg =~ "ruleset"
      assert msg =~ "not in"
    end

    test "rejects unknown prop names" do
      {:error, msg} = Props.resolve(script_with_props(), %{nonexistent: true})
      assert msg =~ "Unknown props"
    end

    test "returns empty map for script without props" do
      {:ok, props} = Props.resolve(script_no_props())
      assert props == %{}
    end

    test "returns empty map for no props and no overrides" do
      {:ok, props} = Props.resolve(script_no_props(), %{})
      assert props == %{}
    end
  end

  # ──────────────────────────────────────────────
  # expand/1
  # ──────────────────────────────────────────────

  describe "expand/1" do
    test "generates all combinations" do
      script = %{
        props: %{
          size: %{type: :atom, values: [:small, :large]},
          color: %{type: :atom, values: [:red, :blue]}
        },
        steps: []
      }

      combos = Props.expand(script)
      assert length(combos) == 4

      assert %{size: :small, color: :red} in combos
      assert %{size: :small, color: :blue} in combos
      assert %{size: :large, color: :red} in combos
      assert %{size: :large, color: :blue} in combos
    end

    test "expands ranges" do
      script = %{
        props: %{
          n: %{type: :integer, range: 1..3}
        },
        steps: []
      }

      combos = Props.expand(script)
      assert length(combos) == 3
      assert %{n: 1} in combos
      assert %{n: 2} in combos
      assert %{n: 3} in combos
    end

    test "caps at 100 combinations" do
      script = %{
        props: %{
          a: %{type: :integer, range: 1..20},
          b: %{type: :integer, range: 1..20}
        },
        steps: []
      }

      combos = Props.expand(script)
      assert length(combos) == 100
    end

    test "returns single empty map for no props" do
      assert Props.expand(script_no_props()) == [%{}]
    end
  end

  # ──────────────────────────────────────────────
  # random/1
  # ──────────────────────────────────────────────

  describe "random/1" do
    test "generates random props within constraints" do
      props = Props.random(script_with_props())

      assert props.player_count in 2..6
      assert props.ruleset in [:draw, :block, :all_fives]
      assert is_boolean(props.verbose)
    end

    test "returns empty map for no props" do
      assert Props.random(script_no_props()) == %{}
    end
  end

  # ──────────────────────────────────────────────
  # describe/1
  # ──────────────────────────────────────────────

  describe "describe/1" do
    test "extracts prop metadata" do
      descriptions = Props.describe(script_with_props())
      assert length(descriptions) == 3

      pc = Enum.find(descriptions, &(&1.name == :player_count))
      assert pc.type == :integer
      assert pc.default == 2
      assert pc.range == 2..6
    end
  end

  # ──────────────────────────────────────────────
  # RunnerV2 integration
  # ──────────────────────────────────────────────

  describe "RunnerV2 integration" do
    test "props are injected into step context" do
      script = %{
        id: "props_integration",
        props: %{
          multiplier: %{type: :integer, default: 3}
        },
        steps: [
          %{
            id: "use_prop",
            name: "Use prop value",
            run: fn ctx ->
              %{result: 10 * ctx.props.multiplier}
            end,
            checks: [
              %{id: "c1", path: "result", assert: "equals", expected: 30}
            ]
          }
        ]
      }

      report = ScryJourney.RunnerV2.run(script)
      assert report.pass
    end

    test "prop overrides work via opts" do
      script = %{
        id: "props_override",
        props: %{
          multiplier: %{type: :integer, default: 3}
        },
        steps: [
          %{
            id: "use_prop",
            run: fn ctx ->
              %{result: 10 * ctx.props.multiplier}
            end,
            checks: [
              %{id: "c1", path: "result", assert: "equals", expected: 50}
            ]
          }
        ]
      }

      report = ScryJourney.RunnerV2.run(script, props: %{multiplier: 5})
      assert report.pass
    end

    test "invalid props return error report" do
      script = %{
        id: "props_invalid",
        props: %{
          count: %{type: :integer, default: 1, range: 1..10}
        },
        steps: [
          %{id: "s1", run: fn _ctx -> %{} end, checks: []}
        ]
      }

      report = ScryJourney.RunnerV2.run(script, props: %{count: 999})
      refute report.pass
      assert report.status == "ERROR"
      assert report.error =~ "Props error"
    end

    test "script without props works normally" do
      script = %{
        id: "no_props_run",
        steps: [
          %{
            id: "s1",
            run: fn _ctx -> %{x: 42} end,
            checks: [%{id: "c1", path: "x", assert: "equals", expected: 42}]
          }
        ]
      }

      report = ScryJourney.RunnerV2.run(script)
      assert report.pass
    end
  end
end
