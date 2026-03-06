defmodule Sacrum.Accounts.WorkflowSteps do
  @moduledoc """
  User-scoped workflow step operations with business logic.

  All operations are scoped to a specific user. Includes transition syncing
  and broadcast support.
  """

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.WorkflowSteps,
    preloads: [],
    default_order: [asc: :step_order, asc: :inserted_at]

  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.WorkflowStep
  alias Sacrum.Repo.WorkflowSteps, as: WorkflowStepsRepo

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

    %WorkflowStep{workflow_id: workflow_id, project_id: project_id, user_id: user_id}
    |> WorkflowStep.create_changeset(attrs)
    |> WorkflowStepsRepo.insert()
    |> Broadcaster.broadcast(:step_created, workflow: :project)
  end

  @doc """
  Update a workflow step.
  """
  @spec update(WorkflowStep.t(), map()) :: {:ok, WorkflowStep.t()} | {:error, Ecto.Changeset.t()}
  def update(%WorkflowStep{} = step, attrs) do
    step
    |> WorkflowStep.update_changeset(attrs)
    |> WorkflowStepsRepo.update()
    |> Broadcaster.broadcast(:step_updated, workflow: :project)
  end

  @doc """
  Delete a workflow step.
  """
  @spec delete(WorkflowStep.t()) :: {:ok, WorkflowStep.t()} | {:error, Ecto.Changeset.t()}
  def delete(%WorkflowStep{} = step) do
    WorkflowStepsRepo.delete(step)
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
end
