defmodule ScryJourney.Props do
  @moduledoc """
  Parameterized journey execution via props.

  Props let journey scripts declare variable inputs that can change
  between runs. This enables scenario matrices, fuzzing, and edge
  case exploration from a single script.

  ## Declaration in scripts

      %{
        id: "match_lifecycle",
        props: %{
          player_count: %{type: :integer, default: 2, range: 2..6},
          ruleset: %{type: :atom, default: :draw, values: [:draw, :block]}
        },
        steps: [
          %{
            id: "create",
            run: fn ctx ->
              # Access props via ctx.props
              players = Enum.map(1..ctx.props.player_count, &"p\#{&1}")
              ...
            end
          }
        ]
      }

  ## Running with props

      # Use defaults
      ScryJourney.verify_script(path)

      # Override specific props
      ScryJourney.verify_script(path, props: %{player_count: 4})

      # Expand all combinations
      ScryJourney.Props.expand(script)
      # => [%{player_count: 2, ruleset: :draw}, %{player_count: 2, ruleset: :block}, ...]
  """

  @doc """
  Resolve props for a script run.

  Merges declared defaults with any overrides, validates types,
  and returns the final props map to inject into context.
  """
  @spec resolve(map(), map()) :: {:ok, map()} | {:error, String.t()}
  def resolve(script, overrides \\ %{}) do
    declarations = Map.get(script, :props, %{})

    if declarations == %{} and overrides == %{} do
      {:ok, %{}}
    else
      with {:ok, defaults} <- extract_defaults(declarations),
           {:ok, merged} <- merge_overrides(defaults, overrides, declarations),
           :ok <- validate_all(merged, declarations) do
        {:ok, merged}
      end
    end
  end

  @doc """
  Expand all prop combinations into a list of prop maps.

  For a script with `player_count: range 2..3` and `ruleset: values [:draw, :block]`,
  returns 4 combinations: [{2,:draw}, {2,:block}, {3,:draw}, {3,:block}].

  Caps at 100 combinations to prevent explosion.
  """
  @spec expand(map()) :: [map()]
  def expand(script) do
    declarations = Map.get(script, :props, %{})

    if declarations == %{} do
      [%{}]
    else
      declarations
      |> Enum.map(fn {name, spec} -> {name, expandable_values(spec)} end)
      |> cartesian_product()
      |> Enum.take(100)
    end
  end

  @doc """
  Generate a random set of props within declared constraints.
  """
  @spec random(map()) :: map()
  def random(script) do
    declarations = Map.get(script, :props, %{})

    Map.new(declarations, fn {name, spec} ->
      {name, random_value(spec)}
    end)
  end

  @doc """
  Extract prop declarations from a script, with metadata.
  """
  @spec describe(map()) :: [map()]
  def describe(script) do
    script
    |> Map.get(:props, %{})
    |> Enum.map(fn {name, spec} ->
      %{
        name: name,
        type: Map.get(spec, :type, :any),
        default: Map.get(spec, :default),
        range: Map.get(spec, :range),
        values: Map.get(spec, :values),
        description: Map.get(spec, :description)
      }
    end)
  end

  # ──────────────────────────────────────────────
  # Resolution internals
  # ──────────────────────────────────────────────

  defp extract_defaults(declarations) do
    defaults =
      Map.new(declarations, fn {name, spec} ->
        {name, Map.get(spec, :default)}
      end)

    {:ok, defaults}
  end

  defp merge_overrides(defaults, overrides, declarations) do
    # Check for unknown prop names
    unknown = Map.keys(overrides) -- Map.keys(declarations)

    if unknown != [] do
      {:error, "Unknown props: #{inspect(unknown)}"}
    else
      {:ok, Map.merge(defaults, overrides)}
    end
  end

  defp validate_all(props, declarations) do
    errors =
      Enum.flat_map(props, fn {name, value} ->
        case Map.get(declarations, name) do
          nil -> []
          spec -> validate_prop(name, value, spec)
        end
      end)

    case errors do
      [] -> :ok
      errs -> {:error, Enum.join(errs, "; ")}
    end
  end

  defp validate_prop(_name, nil, %{default: nil}), do: []
  defp validate_prop(name, nil, _spec), do: ["#{name}: value is nil but no nil default"]

  defp validate_prop(name, value, spec) do
    errors = []
    errors = errors ++ validate_type(name, value, spec)
    errors = errors ++ validate_range(name, value, spec)
    errors = errors ++ validate_values(name, value, spec)
    errors
  end

  defp validate_type(_name, _value, %{type: :any}), do: []
  defp validate_type(_name, value, %{type: :integer}) when is_integer(value), do: []
  defp validate_type(_name, value, %{type: :float}) when is_float(value), do: []
  defp validate_type(_name, value, %{type: :number}) when is_number(value), do: []
  defp validate_type(_name, value, %{type: :string}) when is_binary(value), do: []
  defp validate_type(_name, value, %{type: :atom}) when is_atom(value), do: []
  defp validate_type(_name, value, %{type: :boolean}) when is_boolean(value), do: []

  defp validate_type(name, value, %{type: type}),
    do: ["#{name}: expected #{type}, got #{inspect(value)}"]

  defp validate_type(_, _, _), do: []

  defp validate_range(_name, _value, spec) when not is_map_key(spec, :range), do: []

  defp validate_range(name, value, %{range: %Range{} = range}) do
    if value in range, do: [], else: ["#{name}: #{inspect(value)} not in #{inspect(range)}"]
  end

  defp validate_range(_, _, _), do: []

  defp validate_values(_name, _value, spec) when not is_map_key(spec, :values), do: []

  defp validate_values(name, value, %{values: values}) when is_list(values) do
    if value in values, do: [], else: ["#{name}: #{inspect(value)} not in #{inspect(values)}"]
  end

  defp validate_values(_, _, _), do: []

  # ──────────────────────────────────────────────
  # Expansion
  # ──────────────────────────────────────────────

  defp expandable_values(%{values: values}) when is_list(values), do: values
  defp expandable_values(%{range: %Range{} = range}), do: Enum.to_list(range)
  defp expandable_values(%{default: default}), do: [default]
  defp expandable_values(_), do: [nil]

  defp cartesian_product([]), do: [%{}]

  defp cartesian_product([{name, values} | rest]) do
    rest_products = cartesian_product(rest)

    for value <- values, combo <- rest_products do
      Map.put(combo, name, value)
    end
  end

  # ──────────────────────────────────────────────
  # Random generation
  # ──────────────────────────────────────────────

  defp random_value(%{values: values}) when is_list(values) and values != [] do
    Enum.random(values)
  end

  defp random_value(%{range: %Range{} = range}) do
    Enum.random(range)
  end

  defp random_value(%{type: :integer, default: default}) do
    default || Enum.random(1..100)
  end

  defp random_value(%{type: :boolean}) do
    Enum.random([true, false])
  end

  defp random_value(%{default: default}), do: default
  defp random_value(_), do: nil
end
