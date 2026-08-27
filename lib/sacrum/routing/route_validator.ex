defmodule Sacrum.Routing.RouteValidator do
  @moduledoc """
  Authoritative graph-aware validation for persisted route configurations.

  A present `route_config` must be valid against every incoming predecessor
  contract and every persisted destination edge. Prompt routing is deliberately
  outside this module because it is eligible only when configuration is absent.
  """

  import Ecto.Query

  alias Sacrum.Orchestrator.WorkflowGraph
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{StepTransition, Workflow, WorkflowStep, WorkflowTransition}
  alias Sacrum.Routing.{RouteConfig, RouteContext, RouteEvaluator, RoutePredecessors}

  @levels ["epic", "ticket", "task"]

  @type context :: %{
          predecessors: [map()],
          type_environment: RoutePredecessors.type_environment()
        }
  @type error :: %{
          optional(atom()) => term(),
          code: atom(),
          path: String.t(),
          message: String.t()
        }

  @doc """
  Validates one persisted route step, loading its incoming predecessor context.
  """
  @spec validate(WorkflowStep.t()) :: :ok | {:error, error()}
  def validate(%WorkflowStep{route_config: nil}), do: :ok

  def validate(%WorkflowStep{} = route_step) do
    case WorkflowGraph.validate_route_predecessors(route_step) do
      {:ok, context} ->
        validate(route_step, context)

      {:error, reason} ->
        {:error, attach_route_step(reason, route_step)}
    end
  end

  @doc """
  Validates one persisted route step against a previously loaded predecessor
  context. This allows callers validating a stable graph snapshot to reuse the
  same context without reloading predecessor schemas.
  """
  @spec validate(WorkflowStep.t(), context()) :: :ok | {:error, error()}
  def validate(%WorkflowStep{route_config: nil}, _context), do: :ok

  def validate(%WorkflowStep{} = route_step, context) do
    with :ok <- validate_route_step(route_step),
         {:ok, program} <- RouteConfig.decode(route_step.route_config),
         :ok <- RoutePredecessors.validate(program, context.type_environment),
         :ok <- validate_finite_domain(program, context.type_environment.result_values),
         :ok <- validate_targets(route_step, program) do
      :ok
    else
      {:error, reason} -> {:error, attach_route_step(reason, route_step)}
    end
  end

  defp validate_route_step(%WorkflowStep{step_type: :route}), do: :ok

  defp validate_route_step(_route_step) do
    {:error, error(:route_config_invalid, "$.route_config", "is only supported for route steps")}
  end

  defp validate_finite_domain(program, result_values) do
    closed_rules = Enum.filter(program.rules, &closed_rule?/1)

    case validate_closed_rule_overlaps(program, closed_rules, result_values) do
      :ok -> validate_closed_rule_coverage(program, closed_rules, result_values)
      {:error, _reason} = error -> error
    end
  end

  defp validate_closed_rule_overlaps(program, closed_rules, result_values) do
    combinations = for result <- result_values, level <- @levels, do: {result, level}

    Enum.reduce_while(combinations, :ok, fn {result, level}, :ok ->
      case overlap_error(program, closed_rules, result, level) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp overlap_error(program, closed_rules, result, level) do
    case matching_rule_ids(program, closed_rules, result, level) do
      [_] ->
        :ok

      [] ->
        :ok

      [_first, second | _] ->
        {:error,
         error(
           :route_config_ambiguous,
           "$.rules[#{rule_index(program, second)}].when",
           "overlaps for route.result=#{inspect(result)} and task.level=#{inspect(level)}"
         )}
    end
  end

  defp validate_closed_rule_coverage(%{default: default}, _closed_rules, _result_values)
       when is_map(default),
       do: :ok

  defp validate_closed_rule_coverage(program, closed_rules, result_values) do
    if Enum.all?(program.rules, &closed_rule?/1) do
      case uncovered_combination(program, closed_rules, result_values) do
        nil ->
          :ok

        {result, level} ->
          {:error,
           error(
             :route_config_uncovered,
             "$.rules",
             "does not cover route.result=#{inspect(result)} and task.level=#{inspect(level)}"
           )}
      end
    else
      :ok
    end
  end

  defp uncovered_combination(program, closed_rules, result_values) do
    combinations = for result <- result_values, level <- @levels, do: {result, level}

    Enum.find(combinations, fn {result, level} ->
      matching_rule_ids(program, closed_rules, result, level) == []
    end)
  end

  defp matching_rule_ids(program, closed_rules, result, level) do
    {:ok, context} =
      RouteContext.build(
        %{"route" => %{"result" => result, "handoff" => %{}}},
        %{"level" => level, "tags" => []},
        1
      )

    {:ok, ids} = RouteEvaluator.matching_rule_ids(%{program | rules: closed_rules}, context)
    ids
  end

  defp closed_rule?(%{when: expression}), do: closed_expression?(expression)

  defp closed_expression?(%{kind: kind, expressions: expressions}) when kind in [:all, :any],
    do: Enum.all?(expressions, &closed_expression?/1)

  defp closed_expression?(%{kind: :not, expression: expression}),
    do: closed_expression?(expression)

  defp closed_expression?(%{kind: :predicate, ref: ref}),
    do: ref in [:previous_output_route_result, :task_level]

  defp validate_targets(route_step, program) do
    case validate_rule_targets(route_step, program.rules) do
      :ok -> validate_default_target(route_step, program.default)
      {:error, _reason} = error -> error
    end
  end

  defp validate_rule_targets(route_step, rules) do
    rules
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {%{transition: target}, index}, :ok ->
      path = "$.rules[#{index}].transition"

      case validate_target(route_step, target, path) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_default_target(_route_step, nil), do: :ok

  defp validate_default_target(route_step, target) do
    validate_target(route_step, target, "$.default.transition")
  end

  defp validate_target(route_step, %{type: :intra_workflow, step_id: step_id}, path),
    do: validate_intra_workflow_target(route_step, step_id, path)

  defp validate_target(route_step, %{type: :inter_workflow, workflow_id: workflow_id}, path),
    do: validate_inter_workflow_target(route_step, workflow_id, path)

  defp validate_intra_workflow_target(route_step, step_id, path) do
    valid? =
      Repo.exists?(
        from(transition in StepTransition,
          join: destination in WorkflowStep,
          on: destination.id == transition.to_step_id,
          where:
            transition.from_step_id == ^route_step.id and
              transition.to_step_id == ^step_id and
              transition.user_id == ^route_step.user_id and
              transition.project_id == ^route_step.project_id and
              destination.user_id == ^route_step.user_id and
              destination.project_id == ^route_step.project_id and
              destination.workflow_id == ^route_step.workflow_id
        )
      )

    if valid? do
      :ok
    else
      {:error,
       error(:route_target_invalid, "#{path}.step_id", "must be an outgoing step transition")}
    end
  end

  defp validate_inter_workflow_target(route_step, workflow_id, path) do
    transition =
      Repo.one(
        from(transition in WorkflowTransition,
          join: destination in Workflow,
          on: destination.id == transition.to_workflow_id,
          where:
            transition.from_workflow_id == ^route_step.workflow_id and
              transition.to_workflow_id == ^workflow_id and
              transition.user_id == ^route_step.user_id and
              transition.project_id == ^route_step.project_id and
              destination.user_id == ^route_step.user_id and
              destination.project_id == ^route_step.project_id,
          select: %{
            destination_workflow_id: destination.id,
            initial_step_id: destination.initial_step_id,
            target_step_id: transition.target_step_id
          }
        )
      )

    case transition do
      nil ->
        {:error,
         error(
           :route_target_invalid,
           "#{path}.workflow_id",
           "must be an outgoing workflow transition"
         )}

      transition ->
        validate_workflow_entry(route_step, transition, path)
    end
  end

  defp validate_workflow_entry(route_step, transition, path) do
    if destination_has_entry?(route_step, transition) do
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

  defp destination_has_entry?(route_step, %{target_step_id: step_id} = transition)
       when is_binary(step_id),
       do: destination_entry_step?(route_step, transition.destination_workflow_id, step_id)

  defp destination_has_entry?(route_step, %{initial_step_id: step_id} = transition)
       when is_binary(step_id),
       do: destination_entry_step?(route_step, transition.destination_workflow_id, step_id)

  defp destination_has_entry?(route_step, transition) do
    Repo.exists?(
      from(step in WorkflowStep,
        where:
          step.workflow_id == ^transition.destination_workflow_id and
            step.user_id == ^route_step.user_id and
            step.project_id == ^route_step.project_id
      )
    )
  end

  defp destination_entry_step?(route_step, workflow_id, step_id) do
    Repo.exists?(
      from(step in WorkflowStep,
        where:
          step.id == ^step_id and
            step.workflow_id == ^workflow_id and
            step.user_id == ^route_step.user_id and
            step.project_id == ^route_step.project_id
      )
    )
  end

  defp rule_index(program, rule_id), do: Enum.find_index(program.rules, &(&1.id == rule_id))

  defp attach_route_step(reason, route_step) do
    Map.merge(reason, %{route_step_id: route_step.id, workflow_id: route_step.workflow_id})
  end

  defp error(code, path, message), do: %{code: code, path: path, message: message}
end
