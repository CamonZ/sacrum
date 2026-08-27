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
  alias Sacrum.Repo.Schemas.{Project, StepTransition, Workflow, WorkflowStep, WorkflowTransition}
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
  Revalidates configured routes after a proposed graph mutation.

  Route rows are locked before their graph is read so concurrent mutations that
  affect the same configuration serialize at the validation boundary.
  """
  @spec revalidate_route_ids([binary()]) :: :ok | {:error, error()}
  def revalidate_route_ids(route_ids) do
    route_ids
    |> Enum.uniq()
    |> configured_routes()
    |> validate_routes()
  end

  @doc """
  Validates every configured route before a workflow is entered.

  This is the runtime safety net for new, resumed, and inter-workflow TaskRun
  entry. It deliberately uses the same validator as persistence-time checks.
  """
  @spec validate_workflow(binary(), binary(), binary() | nil) :: :ok | {:error, error()}
  def validate_workflow(_user_id, _project_id, nil), do: :ok

  def validate_workflow(user_id, project_id, workflow_id) do
    validate_routes(
      Repo.all(
        from(step in WorkflowStep,
          where:
            step.workflow_id == ^workflow_id and
              step.user_id == ^user_id and
              step.project_id == ^project_id and
              not is_nil(step.route_config)
        )
      )
    )
  end

  @doc """
  Serializes graph writes within a project before route dependencies are read.

  A route configuration and every topology mutation use the same project-row
  lock, so neither can validate against a graph that another transaction later
  changes before committing.
  """
  @spec lock_project(binary() | nil) :: :ok
  def lock_project(nil), do: :ok

  def lock_project(project_id) do
    Repo.one(from(project in Project, where: project.id == ^project_id, lock: "FOR UPDATE"))
    :ok
  end

  @doc """
  Returns configured routes that directly depend on the supplied workflow steps
  as predecessors or intra-workflow destinations.
  """
  @spec related_route_ids_for_steps([binary()]) :: [binary()]
  def related_route_ids_for_steps([]), do: []

  def related_route_ids_for_steps(step_ids) do
    step_ids = step_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    route_ids =
      direct_route_ids(step_ids) ++
        route_ids_with_transitions(:from, step_ids) ++
        route_ids_with_transitions(:to, step_ids)

    Enum.uniq(route_ids)
  end

  @doc """
  Returns configured routes that depend on a workflow as an inter-workflow
  destination or are defined in that workflow.
  """
  @spec related_route_ids_for_workflows([binary()]) :: [binary()]
  def related_route_ids_for_workflows([]), do: []

  def related_route_ids_for_workflows(workflow_ids) do
    workflow_ids = workflow_ids |> Enum.filter(&is_binary/1) |> Enum.uniq()

    source_workflow_ids =
      Repo.all(
        from(transition in WorkflowTransition,
          where: transition.to_workflow_id in ^workflow_ids,
          select: transition.from_workflow_id
        )
      )

    direct_route_ids_for_workflows(workflow_ids ++ source_workflow_ids)
  end

  @doc """
  Converts a route-validation error into a changeset error for the mutation
  caller while preserving its stable, path-aware explanation.
  """
  @spec error_changeset(Ecto.Changeset.t() | struct(), error()) :: Ecto.Changeset.t()
  def error_changeset(%Ecto.Changeset{} = changeset, reason) do
    Ecto.Changeset.add_error(changeset, :route_config, error_message(reason))
  end

  def error_changeset(record, reason) do
    record
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:route_config, error_message(reason))
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

  defp configured_routes([]), do: []

  defp configured_routes(route_ids) do
    Repo.all(
      from(step in WorkflowStep,
        where: step.id in ^route_ids and not is_nil(step.route_config),
        lock: "FOR UPDATE"
      )
    )
  end

  defp validate_routes(route_steps) do
    Enum.reduce_while(route_steps, :ok, fn route_step, :ok ->
      case validate(route_step) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp direct_route_ids(step_ids) do
    Repo.all(
      from(step in WorkflowStep,
        where: step.id in ^step_ids and not is_nil(step.route_config),
        select: step.id
      )
    )
  end

  defp route_ids_with_transitions(:from, step_ids) do
    Repo.all(
      from(transition in StepTransition,
        join: route_step in WorkflowStep,
        on: route_step.id == transition.to_step_id,
        where: transition.from_step_id in ^step_ids and not is_nil(route_step.route_config),
        select: route_step.id
      )
    )
  end

  defp route_ids_with_transitions(:to, step_ids) do
    Repo.all(
      from(transition in StepTransition,
        join: route_step in WorkflowStep,
        on: route_step.id == transition.from_step_id,
        where: transition.to_step_id in ^step_ids and not is_nil(route_step.route_config),
        select: route_step.id
      )
    )
  end

  defp direct_route_ids_for_workflows(workflow_ids) do
    Repo.all(
      from(step in WorkflowStep,
        where: step.workflow_id in ^workflow_ids and not is_nil(step.route_config),
        select: step.id
      )
    )
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

  defp error_message(%{path: path, message: message}), do: "#{path}: #{message}"
end
