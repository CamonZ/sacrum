defmodule Sacrum.Accounts.WorkflowSteps do
  @moduledoc """
  User-scoped workflow step operations with business logic.

  All operations are scoped to a specific user. Includes transition syncing.
  """

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.WorkflowSteps,
    preloads: [],
    default_order: [asc: :step_order, asc: :inserted_at]

  import Ecto.Query

  alias Sacrum.Orchestrator.Routing.{RouteConfig, RouteContext}
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.StepTransition
  alias Sacrum.Repo.Schemas.WorkflowStep
  alias Sacrum.Repo.WorkflowSteps, as: WorkflowStepsRepo

  @spec resolve_short_id(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, WorkflowStep.t()}
          | {:error, :not_found | :invalid_prefix}
          | {:error, {:ambiguous, [String.t()]}}
  def resolve_short_id(user_id, project_id, workflow_id, prefix) when is_binary(user_id) do
    WorkflowStepsRepo.find_by_uuid_prefix(prefix, project_id, workflow_id, user_id)
  end

  @doc """
  Insert a new workflow step for a user within a workflow.
  Accepts either (workflow_struct, attrs) or (user_id, attrs).
  """
  @spec insert(map(), map()) :: {:ok, WorkflowStep.t()} | {:error, Ecto.Changeset.t()}
  def insert(%{id: workflow_id, project_id: project_id, user_id: user_id}, attrs) do
    attrs =
      attrs
      |> stringify_keys()
      |> Map.put("workflow_id", workflow_id)
      |> Map.put("project_id", project_id)

    insert(user_id, attrs)
  end

  @spec insert(String.t(), map()) :: {:ok, WorkflowStep.t()} | {:error, Ecto.Changeset.t()}
  def insert(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    workflow_id = Map.get(attrs, "workflow_id") || Map.get(attrs, :workflow_id)
    project_id = Map.get(attrs, "project_id") || Map.get(attrs, :project_id)

    changeset =
      %WorkflowStep{workflow_id: workflow_id, project_id: project_id, user_id: user_id}
      |> WorkflowStep.create_changeset(attrs)
      |> validate_route_config()

    WorkflowStepsRepo.insert(changeset)
  end

  @doc """
  Update a workflow step.
  """
  @spec update(WorkflowStep.t(), map()) :: {:ok, WorkflowStep.t()} | {:error, Ecto.Changeset.t()}
  def update(%WorkflowStep{} = step, attrs) do
    changeset =
      step
      |> WorkflowStep.update_changeset(attrs)
      |> validate_route_config()

    WorkflowStepsRepo.update(changeset)
  end

  @doc """
  Delete a workflow step.
  """
  @spec delete(WorkflowStep.t()) ::
          {:ok, WorkflowStep.t()} | {:error, Ecto.Changeset.t()} | {:error, String.t()}
  def delete(%WorkflowStep{} = step) do
    case WorkflowStepsRepo.delete(step) do
      {:error, :assigned_tasks} ->
        {:error, "cannot delete a workflow step that is assigned to one or more tasks"}

      result ->
        result
    end
  end

  @doc """
  Syncs the outgoing transitions for a workflow step.
  """
  @spec sync_transitions(WorkflowStep.t(), list()) ::
          {:ok, list()} | {:error, Ecto.Changeset.t()} | {:error, atom()}
  def sync_transitions(%WorkflowStep{} = step, transitions) when is_list(transitions) do
    WorkflowStepsRepo.sync_transitions(step, transitions)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  defp validate_route_config(%{valid?: false} = changeset), do: changeset

  defp validate_route_config(changeset) do
    case {Ecto.Changeset.get_field(changeset, :step_type),
          Ecto.Changeset.get_field(changeset, :route_config)} do
      {:route, route_config} when is_map(route_config) ->
        case RouteConfig.decode(route_config) do
          {:ok, program} ->
            validate_route_program(changeset, program)

          {:error, %{path: path, message: message}} ->
            Ecto.Changeset.add_error(changeset, :route_config, "#{path}: #{message}")
        end

      _ ->
        changeset
    end
  end

  defp validate_route_program(changeset, program) do
    with :ok <- RouteContext.validate(program),
         :ok <- validate_deterministic_route_program(changeset, program) do
      changeset
    else
      {:error, %{path: path, message: message}} ->
        Ecto.Changeset.add_error(changeset, :route_config, "#{path}: #{message}")
    end
  end

  defp validate_deterministic_route_program(changeset, program) do
    if Ecto.Changeset.get_field(changeset, :prompt) == nil do
      changeset
      |> predecessor_schemas()
      |> RouteContext.derive_type_environment()
      |> case do
        {:ok, type_environment} -> RouteContext.validate(program, type_environment)
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp predecessor_schemas(%{data: %{id: nil}}), do: []

  defp predecessor_schemas(%{data: %{id: route_step_id}}) do
    Repo.all(
      from(transition in StepTransition,
        join: predecessor in WorkflowStep,
        on: predecessor.id == transition.from_step_id,
        where: transition.to_step_id == ^route_step_id,
        select: predecessor.output_schema
      )
    )
  end
end
