%{
  steps: [
    %{
      id: "s1",
      run: fn _ctx -> %{x: 1} end,
      checks: [%{id: "c1", path: "x", assert: :equals, expected: 1}]
    }
  ]
}
