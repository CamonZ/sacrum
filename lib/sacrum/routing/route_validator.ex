defmodule Sacrum.Routing.RouteValidator do
  @moduledoc """
  Pure graph-aware validation for persisted route configurations.

  A present `route_config` must be valid against every incoming predecessor
  contract and every persisted destination edge, read from an in-memory
  snapshot. Callers name the owner workflows whose routes to prove; the
  snapshot also holds support data (outgoing destinations) that those routes
  read. Prompt routing is outside this module: it is eligible only when
  configuration is absent.

  Loading snapshots and revalidating inside write transactions belongs to
  `Sacrum.Repo.RouteValidation`; this module performs no I/O.
  """

  alias Sacrum.Repo.Schemas.WorkflowStep
  alias Sacrum.Routing.{RouteConfig, RouteContext, RouteEvaluator, RoutePredecessors}

  @type step_edge :: %{
          transition_id: binary(),
          from_step_id: binary(),
          to_step_id: binary()
        }

  @type workflow_edge :: %{
          target_step_id: binary() | nil,
          destination_workflow_id: binary(),
          initial_step_id: binary() | nil
        }

  @type snapshot :: %{
          steps: %{optional(binary()) => WorkflowStep.t()},
          step_edges: %{optional(binary()) => [step_edge()]},
          incoming_edges: %{optional(binary()) => [step_edge()]},
          workflow_edges: %{optional({binary(), binary()}) => workflow_edge()}
        }

  @type error :: %{
          optional(atom()) => term(),
          code: atom(),
          path: String.t(),
          message: String.t()
        }

  @doc """
  Validates configured route steps that belong to `owner_ids`.

  Destination workflows appear in the snapshot as support data so target
  checks can see their entry steps; their own routes are not subjects of
  this check.
  """
  @spec validate_snapshot(snapshot(), [binary()]) :: :ok | {:error, error()}
  def validate_snapshot(%{} = snapshot, owner_ids) when is_list(owner_ids) do
    owners = MapSet.new(owner_ids)

    snapshot.steps
    |> Enum.filter(fn {_id, step} ->
      step.route_config && MapSet.member?(owners, step.workflow_id)
    end)
    |> Enum.reduce_while(:ok, fn {_id, step}, :ok ->
      case validate(step, snapshot) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Validates one configured route step against the snapshot.

  A present configuration with no incoming predecessor edge is rejected:
  deterministic routing needs at least one declared result domain.
  """
  @spec validate(WorkflowStep.t(), snapshot()) :: :ok | {:error, error()}
  def validate(%{route_config: nil}, _snapshot), do: :ok

  def validate(route_step, snapshot) do
    with :ok <- validate_route_step_type(route_step),
         {:ok, program} <- RouteConfig.decode(route_step.route_config),
         {:ok, type_environment} <-
           RoutePredecessors.derive_type_environment(predecessor_schemas(route_step, snapshot)),
         :ok <- RoutePredecessors.validate(program, type_environment),
         :ok <- validate_finite_domain(program, type_environment.result_values),
         :ok <- validate_targets(route_step, program, snapshot) do
      :ok
    else
      {:error, reason} -> {:error, attach_route_step(reason, route_step)}
    end
  end

  defp validate_route_step_type(%{step_type: :route}), do: :ok

  defp validate_route_step_type(_route_step) do
    {:error, error(:route_config_invalid, "$.route_config", "is only supported for route steps")}
  end

  @doc """
  Returns the incoming predecessor envelopes for a route step, keeping the
  edge identity so a contract error can identify the configuration to repair.
  """
  @spec predecessor_schemas(WorkflowStep.t(), snapshot()) :: [map()]
  def predecessor_schemas(route_step, snapshot) do
    snapshot.incoming_edges
    |> Map.get(route_step.id, [])
    |> Enum.map(fn edge ->
      source = Map.get(snapshot.steps, edge.from_step_id)

      %{
        transition_id: edge.transition_id,
        source_step_id: edge.from_step_id,
        destination_step_id: route_step.id,
        output_schema: source && source.output_schema
      }
    end)
  end

  #
  # Finite-domain analysis: one pass over result x level proves both overlap
  # and coverage. Overlap is reported in preference to a coverage gap,
  # matching the previous two-pass semantics.
  #

  defp validate_finite_domain(program, result_values) do
    closed_rules = Enum.filter(program.rules, &closed_rule?/1)
    combinations = for result <- result_values, level <- RouteConfig.levels(), do: {result, level}

    combinations
    |> Enum.reduce_while({:ok, nil, nil}, &analyze_combination(&1, &2, program, closed_rules))
    |> report_analysis(program)
  end

  defp analyze_combination({result, level}, {_, overlap, gap} = acc, program, closed_rules) do
    case matches_for(program, closed_rules, result, level) do
      {:ok, ids} when length(ids) > 1 and is_nil(overlap) ->
        {:cont, {:ok, %{rule_id: Enum.at(ids, 1), result: result, level: level}, gap}}

      {:ok, []} when is_nil(gap) and is_nil(program.default) ->
        if length(closed_rules) == length(program.rules) do
          {:cont, {:ok, overlap, %{result: result, level: level}}}
        else
          {:cont, acc}
        end

      {:ok, _ids} ->
        {:cont, acc}

      {:error, _reason} = error ->
        {:halt, error}
    end
  end

  defp report_analysis({:ok, nil, nil}, _program), do: :ok

  defp report_analysis({:ok, nil, %{result: result, level: level}}, _program) do
    {:error,
     error(
       :route_config_uncovered,
       "$.rules",
       "does not cover route.result=#{inspect(result)} and task.level=#{inspect(level)}"
     )}
  end

  defp report_analysis(
         {:ok, %{rule_id: rule_id, result: result, level: level}, _gap},
         program
       ) do
    {:error,
     error(
       :route_config_ambiguous,
       "$.rules[#{rule_index(program, rule_id)}].when",
       "overlaps for route.result=#{inspect(result)} and task.level=#{inspect(level)}"
     )}
  end

  defp report_analysis({:error, _reason} = error, _program), do: error

  defp matches_for(program, closed_rules, result, level) do
    with {:ok, context} <-
           RouteContext.build(
             %{"route" => %{"result" => result, "handoff" => %{}}},
             %{"level" => level, "tags" => []},
             1
           ) do
      RouteEvaluator.matching_rule_ids(%{program | rules: closed_rules}, context)
    end
  end

  #
  # Target validation: reads only snapshot data.
  #

  defp validate_targets(route_step, program, snapshot) do
    case validate_rule_targets(route_step, program.rules, snapshot) do
      :ok -> validate_default_target(route_step, program.default, snapshot)
      {:error, _reason} = error -> error
    end
  end

  defp validate_rule_targets(route_step, rules, snapshot) do
    rules
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {%{transition: target}, index}, :ok ->
      case validate_target(route_step, target, "$.rules[#{index}].transition", snapshot) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_default_target(_route_step, nil, _snapshot), do: :ok

  defp validate_default_target(route_step, target, snapshot) do
    validate_target(route_step, target, "$.default.transition", snapshot)
  end

  defp validate_target(route_step, %{type: :intra_workflow, step_id: step_id}, path, snapshot) do
    outgoing_ids =
      snapshot.step_edges
      |> Map.get(route_step.id, [])
      |> MapSet.new(& &1.to_step_id)

    if MapSet.member?(outgoing_ids, step_id) do
      :ok
    else
      {:error,
       error(:route_target_invalid, "#{path}.step_id", "must be an outgoing step transition")}
    end
  end

  defp validate_target(
         route_step,
         %{type: :inter_workflow, workflow_id: workflow_id},
         path,
         snapshot
       ) do
    case Map.get(snapshot.workflow_edges, {route_step.workflow_id, workflow_id}) do
      nil ->
        {:error,
         error(
           :route_target_invalid,
           "#{path}.workflow_id",
           "must be an outgoing workflow transition"
         )}

      entry ->
        validate_workflow_entry(entry, workflow_id, path, snapshot)
    end
  end

  defp validate_workflow_entry(entry, workflow_id, path, snapshot) do
    step_id = entry.target_step_id || entry.initial_step_id

    cond do
      is_nil(step_id) ->
        validate_any_entry(snapshot, workflow_id, path)

      entry_step?(snapshot, step_id, workflow_id) ->
        :ok

      true ->
        {:error,
         error(
           :route_target_invalid,
           "#{path}.workflow_id",
           "must enter a configured step in the destination workflow"
         )}
    end
  end

  defp entry_step?(snapshot, step_id, workflow_id) do
    case Map.get(snapshot.steps, step_id) do
      %{workflow_id: ^workflow_id} -> true
      _ -> false
    end
  end

  defp validate_any_entry(snapshot, workflow_id, path) do
    if Enum.any?(snapshot.steps, fn {_id, step} -> step.workflow_id == workflow_id end) do
      :ok
    else
      {:error,
       error(
         :route_target_invalid,
         "#{path}.workflow_id",
         "must enter a configured step in the destination workflow"
       )}
    end
  end

  defp rule_index(program, rule_id), do: Enum.find_index(program.rules, &(&1.id == rule_id))

  defp attach_route_step(reason, route_step) do
    Map.merge(reason, %{route_step_id: route_step.id, workflow_id: route_step.workflow_id})
  end

  defp closed_rule?(%{when: expression}), do: closed_expression?(expression)

  defp closed_expression?(%{kind: kind, expressions: expressions}) when kind in [:all, :any],
    do: Enum.all?(expressions, &closed_expression?/1)

  defp closed_expression?(%{kind: :not, expression: expression}),
    do: closed_expression?(expression)

  defp closed_expression?(%{kind: :predicate, ref: ref}),
    do: ref in [:previous_output_route_result, :task_level]

  defp error(code, path, message), do: %{code: code, path: path, message: message}
end
