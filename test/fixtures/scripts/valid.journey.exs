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
