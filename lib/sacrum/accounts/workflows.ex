defmodule Sacrum.Accounts.Workflows do
  @moduledoc """
  User-scoped workflow operations with business logic.

  All operations are scoped to a specific user. Includes transition syncing
  and broadcast support.
  """

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.Workflows,
    preloads: [:transitions],
    default_order: [asc: :display_order, asc: :inserted_at]

  alias Sacrum.Repo
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.Workflow
  alias Sacrum.Repo.Schemas.WorkflowTransition
  alias Sacrum.Repo.Workflows, as: WorkflowsRepo

  import Ecto.Query

  @spec resolve_short_id(String.t(), String.t(), String.t()) ::
          {:ok, Workflow.t()}
          | {:error, :not_found | :invalid_prefix}
          | {:error, {:ambiguous, [String.t()]}}
  def resolve_short_id(user_id, project_id, prefix) when is_binary(user_id) do
    WorkflowsRepo.find_by_uuid_prefix(prefix, project_id, user_id)
  end

  @doc """
  Insert a new workflow for a user within a project.
  Accepts either (project_struct, attrs) or (user_id, project_id, attrs).
  """
  @spec insert(map(), map()) :: {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def insert(%{id: project_id, user_id: user_id}, attrs) do
    insert(user_id, project_id, attrs)
  end

  @spec insert(String.t(), String.t(), map()) ::
          {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def insert(user_id, project_id, attrs) when is_binary(user_id) and is_binary(project_id) do
    fn -> do_insert(user_id, project_id, attrs) end
    |> maybe_with_demote(project_id, nil, attrs)
    |> Broadcaster.broadcast(:workflow_created, :project)
  end

  defp do_insert(user_id, project_id, attrs) do
    %Workflow{project_id: project_id, user_id: user_id}
    |> Workflow.create_changeset(attrs)
    |> WorkflowsRepo.insert()
  end

  @doc """
  Update a workflow.
  """
  @spec update(Workflow.t(), map()) ::
          {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()} | {:error, atom()}
  def update(%Workflow{} = workflow, attrs) do
    with :ok <- validate_is_final_no_outgoing_transitions(workflow, attrs) do
      fn -> do_update(workflow, attrs) end
      |> maybe_with_demote(workflow.project_id, workflow.id, attrs)
      |> Broadcaster.broadcast(:workflow_updated, :project)
    end
  end

  defp maybe_with_demote(mutate_fun, project_id, exclude_id, attrs) do
    if default_requested?(attrs) do
      with_demote(project_id, exclude_id, mutate_fun)
    else
      mutate_fun.()
    end
  end

  defp do_update(%Workflow{} = workflow, attrs) do
    workflow
    |> Workflow.update_changeset(attrs)
    |> WorkflowsRepo.update()
  end

  # Demote + mutate in one transaction so the project never observes zero or
  # two defaults mid-flight. `exclude_id` (the workflow being updated) keeps
  # re-setting the existing default idempotent.
  defp with_demote(project_id, exclude_id, mutate_fun) do
    Repo.transaction(fn ->
      demote_existing_default(project_id, exclude_id)

      case mutate_fun.() do
        {:ok, result} -> result
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  defp demote_existing_default(project_id, exclude_workflow_id) do
    query =
      from(w in Workflow,
        where: w.project_id == ^project_id and w.is_default == true
      )

    query =
      if is_nil(exclude_workflow_id) do
        query
      else
        from(w in query, where: w.id != ^exclude_workflow_id)
      end

    Repo.update_all(query, set: [is_default: false, updated_at: DateTime.utc_now()])
  end

  defp default_requested?(attrs) do
    Map.get(attrs, :is_default, Map.get(attrs, "is_default")) == true
  end

  defp validate_is_final_no_outgoing_transitions(%Workflow{id: id}, attrs) do
    is_final = Map.get(attrs, :is_final, Map.get(attrs, "is_final"))

    if is_final == true do
      count =
        Sacrum.Repo.one(
          from(t in WorkflowTransition, where: t.from_workflow_id == ^id, select: count(t.id))
        )

      if count > 0 do
        {:error, :is_final_with_outgoing_transitions}
      else
        :ok
      end
    else
      :ok
    end
  end

  @doc """
  Delete a workflow.
  """
  @spec delete(Workflow.t()) :: {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Workflow{} = workflow) do
    WorkflowsRepo.delete(workflow)
  end

  @doc """
  Syncs the transitions for a workflow.
  """
  @spec sync_transitions(Workflow.t(), list()) :: {:ok, list()} | {:error, Ecto.Changeset.t()}
  def sync_transitions(%Workflow{} = workflow, transition_maps) when is_list(transition_maps) do
    WorkflowsRepo.sync_transitions(workflow, transition_maps)
  end

  @doc """
  Returns workflows in a project plus batched aggregates for the pipeline view.
  """
  @spec pipeline_summary(String.t(), String.t()) ::
          {:ok, list(Workflow.t()), %{required(atom()) => map()}}
  def pipeline_summary(user_id, project_id) when is_binary(user_id) and is_binary(project_id) do
    WorkflowsRepo.pipeline_summary(user_id, project_id)
  end
end
