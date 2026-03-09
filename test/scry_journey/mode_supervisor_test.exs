defmodule ScryJourney.ModeSupervisorTest do
  use ExUnit.Case, async: true

  alias ScryJourney.ModeSupervisor

  # ──────────────────────────────────────────────
  # Fixtures
  # ──────────────────────────────────────────────

  defp passing_script(id) do
    %{
      id: id,
      steps: [
        %{
          id: "s1",
          run: fn _ctx -> %{x: 1} end,
          checks: [%{id: "c1", path: "x", assert: "equals", expected: 1}]
        }
      ]
    }
  end

  defp failing_script(id) do
    %{
      id: id,
      steps: [
        %{
          id: "s1",
          run: fn _ctx -> %{x: 99} end,
          checks: [%{id: "c1", path: "x", assert: "equals", expected: 1}]
        }
      ]
    }
  end

  # ──────────────────────────────────────────────
  # Lifecycle
  # ──────────────────────────────────────────────

  describe "lifecycle" do
    test "starts with inline scripts" do
      scripts = [
        {"j1", passing_script("j1")},
        {"j2", passing_script("j2")}
      ]

      {:ok, sup} = ModeSupervisor.start_link(scripts: scripts, interval: 60_000)

      Process.sleep(100)

      health = ModeSupervisor.health(sup)
      assert health.total == 2
      assert health.healthy == 2
      assert health.failing == 0
      assert health.all_healthy

      ModeSupervisor.stop(sup)
    end

    test "can be stopped cleanly" do
      {:ok, sup} =
        ModeSupervisor.start_link(scripts: [{"j1", passing_script("j1")}], interval: 60_000)

      Process.sleep(50)
      assert Process.alive?(sup)

      ModeSupervisor.stop(sup)
      Process.sleep(10)
      refute Process.alive?(sup)
    end
  end

  # ──────────────────────────────────────────────
  # Health reporting
  # ──────────────────────────────────────────────

  describe "health" do
    test "reports mixed health correctly" do
      scripts = [
        {"healthy", passing_script("healthy")},
        {"sick", failing_script("sick")}
      ]

      {:ok, sup} = ModeSupervisor.start_link(scripts: scripts, interval: 60_000)
      Process.sleep(100)

      health = ModeSupervisor.health(sup)
      assert health.total == 2
      assert health.healthy == 1
      assert health.failing == 1
      refute health.all_healthy

      ModeSupervisor.stop(sup)
    end

    test "list returns per-watcher status" do
      scripts = [
        {"a", passing_script("a")},
        {"b", passing_script("b")}
      ]

      {:ok, sup} = ModeSupervisor.start_link(scripts: scripts, interval: 60_000)
      Process.sleep(100)

      statuses = ModeSupervisor.list(sup)
      assert length(statuses) == 2

      ids = Enum.map(statuses, & &1.journey_id) |> Enum.sort()
      assert ids == ["a", "b"]

      ModeSupervisor.stop(sup)
    end
  end

  # ──────────────────────────────────────────────
  # Dynamic management
  # ──────────────────────────────────────────────

  describe "add/remove" do
    test "add_script adds a new watcher" do
      {:ok, sup} = ModeSupervisor.start_link(interval: 60_000)

      assert {:ok, _pid} = ModeSupervisor.add_script(sup, passing_script("new"), [])
      Process.sleep(100)

      health = ModeSupervisor.health(sup)
      assert health.total == 1
      assert health.healthy == 1

      ModeSupervisor.stop(sup)
    end

    test "add_script rejects duplicates" do
      {:ok, sup} = ModeSupervisor.start_link(interval: 60_000)

      assert {:ok, _pid} = ModeSupervisor.add_script(sup, passing_script("dup"), [])

      assert {:error, {:already_watching, "dup"}} =
               ModeSupervisor.add_script(sup, passing_script("dup"), [])

      ModeSupervisor.stop(sup)
    end

    test "remove stops and removes a watcher" do
      scripts = [
        {"keep", passing_script("keep")},
        {"drop", passing_script("drop")}
      ]

      {:ok, sup} = ModeSupervisor.start_link(scripts: scripts, interval: 60_000)
      Process.sleep(50)

      assert :ok = ModeSupervisor.remove(sup, "drop")

      health = ModeSupervisor.health(sup)
      assert health.total == 1

      ids = Enum.map(health.watchers, & &1.journey_id)
      assert "keep" in ids
      refute "drop" in ids

      ModeSupervisor.stop(sup)
    end

    test "remove returns error for unknown id" do
      {:ok, sup} = ModeSupervisor.start_link(interval: 60_000)
      assert {:error, :not_found} = ModeSupervisor.remove(sup, "nonexistent")
      ModeSupervisor.stop(sup)
    end
  end

  # ──────────────────────────────────────────────
  # Bulk operations
  # ──────────────────────────────────────────────

  describe "bulk operations" do
    test "run_all triggers immediate execution" do
      scripts = [
        {"r1", passing_script("r1")},
        {"r2", passing_script("r2")}
      ]

      {:ok, sup} = ModeSupervisor.start_link(scripts: scripts, interval: 60_000)
      Process.sleep(100)

      initial_runs =
        ModeSupervisor.list(sup)
        |> Enum.map(& &1.runs)
        |> Enum.sum()

      ModeSupervisor.run_all(sup)
      Process.sleep(100)

      new_runs =
        ModeSupervisor.list(sup)
        |> Enum.map(& &1.runs)
        |> Enum.sum()

      assert new_runs > initial_runs

      ModeSupervisor.stop(sup)
    end

    test "pause_all and resume_all work" do
      scripts = [{"p1", passing_script("p1")}]

      {:ok, sup} = ModeSupervisor.start_link(scripts: scripts, interval: 100)
      Process.sleep(50)

      ModeSupervisor.pause_all(sup)
      Process.sleep(20)

      [status] = ModeSupervisor.list(sup)
      assert status.state == :paused

      count_at_pause = status.runs

      Process.sleep(200)

      [status] = ModeSupervisor.list(sup)
      assert status.runs == count_at_pause

      ModeSupervisor.resume_all(sup)
      Process.sleep(50)

      [status] = ModeSupervisor.list(sup)
      assert status.state == :watching
      assert status.runs > count_at_pause

      ModeSupervisor.stop(sup)
    end
  end
end
