defmodule ScryJourney.Context do
  @moduledoc """
  Context map operations for journey v2 scripts.

  Context is a flat map that accumulates data across steps.
  Each step's return value is merged in, so later steps can
  access data from earlier steps.
  """

  @doc "Create a new empty context."
  @spec new() :: map()
  def new, do: %{}

  @doc """
  Merge a step result into the context.

  - Maps are merged directly (last-writer-wins)
  - `{:ok, map}` tuples are unwrapped and merged
  - Other values are stored under the `:result` key
  """
  @spec merge(map(), term()) :: map()
  def merge(ctx, step_result) when is_map(ctx) and is_map(step_result) do
    Map.merge(ctx, step_result)
  end

  def merge(ctx, {:ok, map}) when is_map(ctx) and is_map(map) do
    Map.merge(ctx, map)
  end

  def merge(ctx, other) when is_map(ctx) do
    Map.put(ctx, :result, other)
  end

  @doc """
  Resolve a reference that may be a context key.

  If `ref` is an atom that exists as a key in the context, returns
  the context value. Otherwise returns the ref as-is (for registered
  process names, PIDs, strings, etc.).
  """
  @spec resolve_ref(map(), term()) :: term()
  def resolve_ref(ctx, ref) when is_map(ctx) and is_atom(ref) do
    if Map.has_key?(ctx, ref), do: Map.get(ctx, ref), else: ref
  end

  def resolve_ref(_ctx, value), do: value

  @doc """
  Resolve all resolvable elements in an await condition tuple.

  Walks the tuple and resolves atom elements at positions that
  represent process references (position 1 in most condition types).
  """
  @spec resolve_condition(tuple(), map()) :: tuple()
  def resolve_condition(condition, ctx) when is_tuple(condition) and is_map(ctx) do
    list = Tuple.to_list(condition)

    resolved =
      case list do
        [type, process | rest] when type in [:process_state, :process_alive, :process_dead] ->
          [type, resolve_ref(ctx, process) | rest]

        [type, table | rest] when type in [:ets_entry, :ets_match] ->
          [type, resolve_ref(ctx, table) | rest]

        _ ->
          list
      end

    List.to_tuple(resolved)
  end
end
