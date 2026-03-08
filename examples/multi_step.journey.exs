# Example v2 journey script — multi-step with context threading
#
# This script demonstrates:
# - Context threading between steps
# - Checkpoint assertions on accumulated context
# - Teardown guarantee
#
# Run with:
#   ScryJourney.verify_script("examples/multi_step.journey.exs")

%{
  id: "multi_step_example",
  name: "Multi-Step Example",
  description: "Demonstrate context threading and per-step assertions",
  timeout_ms: 10_000,
  steps: [
    %{
      id: "create_agent",
      name: "Start an Agent process",
      run: fn _ctx ->
        {:ok, pid} = Agent.start_link(fn -> %{count: 0, items: []} end)
        %{agent: pid}
      end,
      checks: [
        %{id: "agent_started", path: "agent", assert: "present"}
      ]
    },
    %{
      id: "add_items",
      name: "Add items to the agent",
      run: fn ctx ->
        Agent.update(ctx.agent, fn state ->
          %{state | count: 3, items: ["a", "b", "c"]}
        end)

        state = Agent.get(ctx.agent, & &1)
        %{count: state.count, items: state.items}
      end,
      checks: [
        %{id: "item_count", path: "count", assert: "equals", expected: 3},
        %{id: "has_items", path: "items", assert: "length_equals", expected: 3}
      ]
    },
    %{
      id: "verify_state",
      name: "Verify final agent state",
      run: fn ctx ->
        state = Agent.get(ctx.agent, & &1)
        %{final_count: state.count, has_b: "b" in state.items}
      end,
      checks: [
        %{id: "final_count", path: "final_count", assert: "integer_gte", min: 1},
        %{id: "contains_b", path: "has_b", assert: "truthy"}
      ]
    }
  ],
  teardown: fn ctx ->
    if ctx[:agent] && Process.alive?(ctx.agent) do
      Agent.stop(ctx.agent)
    end
  end
}
