defmodule ScryJourney.ReportTest do
  use ExUnit.Case, async: true

  alias ScryJourney.Report

  @card %{
    id: "test_card",
    name: "Test Journey",
    schema_version: "journey_card/v1"
  }

  describe "build/3" do
    test "builds a passing report" do
      checkpoints = [
        %{
          id: "c1",
          status: "PASS",
          path: "a",
          assert: "present",
          actual: 1,
          expected: nil,
          message: "present"
        },
        %{
          id: "c2",
          status: "PASS",
          path: "b",
          assert: "equals",
          actual: 5,
          expected: 5,
          message: "equals"
        }
      ]

      report = Report.build(@card, checkpoints)
      assert report.pass == true
      assert report.status == "PASS"
      assert report.card_id == "test_card"
      assert report.card_name == "Test Journey"
      assert report.checkpoint_counts == %{pass: 2, fail: 0}
      assert length(report.checkpoints) == 2
    end

    test "builds a failing report" do
      checkpoints = [
        %{
          id: "c1",
          status: "PASS",
          path: "a",
          assert: "present",
          actual: 1,
          expected: nil,
          message: "ok"
        },
        %{
          id: "c2",
          status: "FAIL",
          path: "b",
          assert: "equals",
          actual: 3,
          expected: 5,
          message: "fail"
        }
      ]

      report = Report.build(@card, checkpoints)
      assert report.pass == false
      assert report.status == "FAIL"
      assert report.checkpoint_counts == %{pass: 1, fail: 1}
    end

    test "includes metadata" do
      report =
        Report.build(@card, [], %{transport: "scry", timeout_ms: 3000, result: %{ok: true}})

      assert report.transport == "scry"
      assert report.timeout_ms == 3000
      assert report.result == %{ok: true}
    end
  end

  describe "build_error/2" do
    test "builds an error report" do
      report = Report.build_error(@card, "Connection refused")
      assert report.pass == false
      assert report.status == "ERROR"
      assert report.error == "Connection refused"
      assert report.checkpoints == []
      assert report.checkpoint_counts == %{pass: 0, fail: 0}
    end

    test "formats non-string errors" do
      report = Report.build_error(@card, {:connection_failed, :myapp@localhost})
      assert report.error =~ "connection_failed"
    end
  end
end
