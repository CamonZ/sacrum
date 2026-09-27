defmodule Sacrum.Routing.RouteOverlap do
  @moduledoc """
  Pairwise overlap analysis for deterministic route rules.

  Each rule is normalized to DNF, and each conjunction becomes a box: one
  domain per constrained reference (finite set, co-finite string set, or
  schema-clamped numeric intervals). Two rules overlap when a box of each
  intersects on every reference both constrain, under any one predecessor
  schema. Conjunctions reading `task.tags` or `execution.step_visit_count`,
  and rules whose DNF exceeds `@max_conjunctions`, are not modeled and are
  left to runtime `:route_ambiguous_match` detection.
  """

  alias Sacrum.Routing.{RouteConfig, RoutePredecessors, RouteValue}

  @max_conjunctions 64

  @negations %{eq: :neq, neq: :eq, in: :nin, nin: :in, lt: :gte, gte: :lt, lte: :gt, gt: :lte}

  @type error :: %{code: :route_config_ambiguous, path: String.t(), message: String.t()}

  @doc """
  Reports the first overlapping pair, ordered by the later rule and then the
  earlier one, at the later rule's `when`.
  """
  @spec validate(RouteConfig.t(), RoutePredecessors.type_environment()) ::
          :ok | {:error, error()}
  def validate(%{rules: rules}, %{predecessors: predecessors}) do
    normal_forms = Enum.map(rules, &normal_form(&1.when))

    boxes_by_predecessor =
      Enum.map(predecessors, fn %{schema: schema} ->
        normal_forms |> Enum.map(&boxes(&1, schema)) |> List.to_tuple()
      end)

    pairs =
      for later <- 1..(length(rules) - 1)//1, earlier <- 0..(later - 1)//1, do: {earlier, later}

    Enum.find_value(pairs, :ok, fn {earlier, later} ->
      with witness when not is_nil(witness) <- find_overlap(boxes_by_predecessor, earlier, later) do
        {:error, ambiguous(rules, earlier, later, witness)}
      end
    end)
  end

  defp find_overlap(boxes_by_predecessor, earlier, later) do
    Enum.find_value(boxes_by_predecessor, &pair_witness(elem(&1, earlier), elem(&1, later)))
  end

  defp pair_witness(left_boxes, right_boxes) do
    for(left <- left_boxes, right <- right_boxes, do: {left, right})
    |> Enum.find_value(fn {left, right} ->
      case intersect_boxes(left, right) do
        {:ok, witness} -> witness
        :empty -> nil
      end
    end)
  end

  defp ambiguous(rules, earlier, later, witness) do
    %{
      code: :route_config_ambiguous,
      path: "$.rules[#{later}].when",
      message: "overlaps rule #{inspect(Enum.at(rules, earlier).id)} for #{describe_box(witness)}"
    }
  end

  # Rule matching is three-valued (a missing value never matches, even
  # negated), and Kleene logic keeps De Morgan and distributivity, so a rule
  # matches exactly when every literal of some DNF conjunction holds on
  # present values.

  defp normal_form(expression) do
    case disjunction(expression, false) do
      {:ok, conjunctions} -> conjunctions
      :unbounded -> []
    end
  end

  defp disjunction(%{kind: :predicate} = predicate, negated?),
    do: {:ok, [[literal(predicate, negated?)]]}

  defp disjunction(%{kind: :not, expression: expression}, negated?),
    do: disjunction(expression, not negated?)

  defp disjunction(%{kind: kind, expressions: expressions}, negated?) do
    {combine, identity} =
      if kind == :all != negated?, do: {&conjoin/2, [[]]}, else: {&disjoin/2, []}

    Enum.reduce_while(expressions, {:ok, identity}, fn expression, {:ok, acc} ->
      with {:ok, conjunctions} <- disjunction(expression, negated?),
           {:ok, combined} <- combine.(acc, conjunctions) do
        {:cont, {:ok, combined}}
      else
        :unbounded -> {:halt, :unbounded}
      end
    end)
  end

  defp conjoin(left, right) when length(left) * length(right) <= @max_conjunctions,
    do: {:ok, for(l <- left, r <- right, do: l ++ r)}

  defp conjoin(_left, _right), do: :unbounded

  defp disjoin(left, right) when length(left) + length(right) <= @max_conjunctions,
    do: {:ok, left ++ right}

  defp disjoin(_left, _right), do: :unbounded

  defp literal(%{ref: ref, operator: operator, value: value}, false),
    do: %{ref: ref, operator: operator, value: value}

  defp literal(%{ref: ref, operator: operator, value: value}, true),
    do: %{ref: ref, operator: Map.get(@negations, operator, {:not, operator}), value: value}

  defp boxes(conjunctions, schema) do
    Enum.flat_map(conjunctions, fn literals ->
      case box(literals, schema) do
        {:ok, box} -> [box]
        :empty -> []
      end
    end)
  end

  # An unmodeled literal drops its whole conjunction: the remaining boxes
  # under-approximate the rule, so any overlap they show is real.
  defp box(literals, schema) do
    Enum.reduce_while(literals, {:ok, []}, fn literal, {:ok, box} ->
      with {:ok, domain} <- literal_domain(literal, schema),
           {:ok, box} <- constrain(box, literal.ref, domain) do
        {:cont, {:ok, box}}
      else
        _empty_or_unmodeled -> {:halt, :empty}
      end
    end)
  end

  defp intersect_boxes(left, right) do
    Enum.reduce_while(right, {:ok, left}, fn {ref, domain}, {:ok, box} ->
      case constrain(box, ref, domain) do
        {:ok, box} -> {:cont, {:ok, box}}
        :empty -> {:halt, :empty}
      end
    end)
  end

  defp constrain(box, ref, domain) do
    domain =
      case List.keyfind(box, ref, 0) do
        {^ref, existing} -> intersect(existing, domain)
        nil -> domain
      end

    cond do
      empty?(domain) -> :empty
      List.keymember?(box, ref, 0) -> {:ok, List.keyreplace(box, ref, 0, {ref, domain})}
      true -> {:ok, [{ref, domain} | box]}
    end
  end

  defp literal_domain(%{ref: :task_level} = literal, _schema),
    do: {:ok, finite(RouteConfig.levels(), literal)}

  defp literal_domain(%{ref: "previous_output." <> _path = ref} = literal, schema) do
    case RoutePredecessors.leaf_schema(schema, ref) do
      {:ok, leaf} -> leaf_domain(leaf, literal)
      :undeclared -> :unmodeled
    end
  end

  defp literal_domain(_literal, _schema), do: :unmodeled

  defp leaf_domain(%{"enum" => enum}, literal) when is_list(enum),
    do: {:ok, finite(enum, literal)}

  defp leaf_domain(%{"type" => "boolean"}, literal), do: {:ok, finite([true, false], literal)}

  defp leaf_domain(%{"type" => "string"}, %{operator: operator, value: value}) do
    case operator do
      :eq -> {:ok, {:set, [value]}}
      :in -> {:ok, {:set, value}}
      :neq -> {:ok, {:cofinite, [value]}}
      :nin -> {:ok, {:cofinite, value}}
      _operator -> :unmodeled
    end
  end

  defp leaf_domain(%{"type" => type} = leaf, literal) when type in ["number", "integer"] do
    integer? = type == "integer"
    universe = {leaf["minimum"], true, leaf["maximum"], true}

    case operator_intervals(literal) do
      {:ok, intervals} ->
        {:ok,
         {:intervals, integer?,
          intervals
          |> Enum.map(&intersect_interval(&1, universe, integer?))
          |> Enum.reject(&is_nil/1)}}

      :unmodeled ->
        :unmodeled
    end
  end

  defp leaf_domain(_leaf, _literal), do: :unmodeled

  defp finite(universe, %{operator: operator, value: value}),
    do: {:set, Enum.filter(universe, &holds?(operator, &1, value))}

  defp holds?(operator, actual, expected)
       when operator in [:eq, :neq, :in, :nin, :lt, :lte, :gt, :gte],
       do: RouteValue.holds?(operator, actual, expected)

  defp holds?(_operator, _actual, _expected), do: false

  # Intervals are `{low, low_closed?, high, high_closed?}`; a nil bound is
  # unbounded.
  defp operator_intervals(%{operator: :eq, value: value}), do: {:ok, [point(value)]}
  defp operator_intervals(%{operator: :in, value: values}), do: {:ok, Enum.map(values, &point/1)}
  defp operator_intervals(%{operator: :neq, value: value}), do: {:ok, gaps([value])}
  defp operator_intervals(%{operator: :nin, value: values}), do: {:ok, gaps(values)}
  defp operator_intervals(%{operator: :lt, value: value}), do: {:ok, [{nil, false, value, false}]}
  defp operator_intervals(%{operator: :lte, value: value}), do: {:ok, [{nil, false, value, true}]}
  defp operator_intervals(%{operator: :gt, value: value}), do: {:ok, [{value, false, nil, false}]}
  defp operator_intervals(%{operator: :gte, value: value}), do: {:ok, [{value, true, nil, false}]}
  defp operator_intervals(_literal), do: :unmodeled

  defp point(value), do: {value, true, value, true}

  defp gaps(values) do
    bounds = values |> Enum.sort(&(RouteValue.compare(&1, &2) != :gt)) |> dedup_values()
    lows = [nil | bounds]
    highs = List.insert_at(bounds, -1, nil)
    Enum.zip_with(lows, highs, fn low, high -> {low, false, high, false} end)
  end

  defp dedup_values(values) do
    values
    |> Enum.chunk_while([], &dedup_chunk/2, &{:cont, &1, []})
    |> Enum.map(&hd/1)
  end

  defp dedup_chunk(value, [previous | _] = chunk) do
    if RouteValue.equal?(value, previous), do: {:cont, chunk}, else: {:cont, chunk, [value]}
  end

  defp dedup_chunk(value, []), do: {:cont, [value]}

  defp intersect({:set, left}, {:set, right}),
    do: {:set, Enum.filter(left, &RouteValue.member?(&1, right))}

  defp intersect({:set, values}, {:cofinite, excluded}),
    do: {:set, Enum.reject(values, &RouteValue.member?(&1, excluded))}

  defp intersect({:cofinite, _excluded} = cofinite, {:set, _values} = set),
    do: intersect(set, cofinite)

  defp intersect({:cofinite, left}, {:cofinite, right}), do: {:cofinite, Enum.uniq(left ++ right)}

  defp intersect({:intervals, integer?, left}, {:intervals, integer?, right}) do
    {:intervals, integer?,
     for(l <- left, r <- right, interval = intersect_interval(l, r, integer?), do: interval)}
  end

  # One reference has one universe per schema, so domains of different
  # kinds never meet; treating them as disjoint keeps the analysis sound.
  defp intersect(_left, _right), do: {:set, []}

  defp empty?({:set, []}), do: true
  defp empty?({:intervals, _integer?, []}), do: true
  defp empty?(_domain), do: false

  defp intersect_interval({left_low, left_low?, left_high, left_high?}, right, integer?) do
    {right_low, right_low?, right_high, right_high?} = right
    {low, low?} = tighter_low({left_low, left_low?}, {right_low, right_low?})
    {high, high?} = tighter_high({left_high, left_high?}, {right_high, right_high?})

    {low, low?, high, high?}
    |> normalize(integer?)
    |> nonempty()
  end

  defp tighter_low({nil, _closed?}, bound), do: bound
  defp tighter_low(bound, {nil, _closed?}), do: bound

  defp tighter_low({left, left?}, {right, right?}) do
    case RouteValue.compare(left, right) do
      :gt -> {left, left?}
      :lt -> {right, right?}
      :eq -> {left, left? and right?}
    end
  end

  defp tighter_high({nil, _closed?}, bound), do: bound
  defp tighter_high(bound, {nil, _closed?}), do: bound

  defp tighter_high({left, left?}, {right, right?}) do
    case RouteValue.compare(left, right) do
      :lt -> {left, left?}
      :gt -> {right, right?}
      :eq -> {left, left? and right?}
    end
  end

  defp normalize(interval, false), do: interval

  defp normalize({low, low?, high, high?}, true) do
    low =
      if is_nil(low), do: nil, else: if(low?, do: ceil_integer(low), else: floor_integer(low) + 1)

    high =
      if is_nil(high),
        do: nil,
        else: if(high?, do: floor_integer(high), else: ceil_integer(high) - 1)

    {low, not is_nil(low), high, not is_nil(high)}
  end

  defp nonempty({low, _low?, high, _high?} = interval) when is_nil(low) or is_nil(high),
    do: interval

  defp nonempty({low, low?, high, high?} = interval) do
    case RouteValue.compare(low, high) do
      :lt -> interval
      :eq when low? and high? -> interval
      _empty -> nil
    end
  end

  defp ceil_integer(value) when is_integer(value), do: value
  defp ceil_integer(value), do: value |> Float.ceil() |> trunc()

  defp floor_integer(value) when is_integer(value), do: value
  defp floor_integer(value), do: value |> Float.floor() |> trunc()

  defp describe_box(box) do
    box
    |> Enum.reverse()
    |> Enum.sort_by(fn {ref, _domain} -> ref != :task_level end)
    |> Enum.map_join(", ", fn {ref, domain} -> reference_name(ref) <> describe(domain) end)
  end

  defp reference_name(:task_level), do: "task.level"
  defp reference_name("previous_output." <> path), do: path

  defp describe({:set, [value]}), do: "=#{inspect(value)}"
  defp describe({:set, values}), do: " in #{inspect(values)}"
  defp describe({:cofinite, [value]}), do: "!=#{inspect(value)}"
  defp describe({:cofinite, values}), do: " not in #{inspect(values)}"

  defp describe({:intervals, _integer?, intervals}) do
    if Enum.all?(intervals, &match?({value, true, value, true}, &1)) do
      case Enum.map(intervals, &elem(&1, 0)) do
        [value] -> "=#{value}"
        values -> " in #{inspect(values)}"
      end
    else
      " in " <> Enum.map_join(intervals, " or ", &describe_interval/1)
    end
  end

  defp describe_interval({low, low?, high, high?}) do
    "#{if low?, do: "[", else: "("}#{low || "-inf"}, #{high || "inf"}#{if high?, do: "]", else: ")"}"
  end
end
