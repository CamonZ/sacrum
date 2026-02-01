defmodule Sacrum.Repo.Workflows do
  @moduledoc """
  CRUD operations for workflows, scoped to a project.

  ## Error Contract

  - `get/1` returns `{:ok, workflow}` or `{:error, :not_found}`
  - `insert/2` returns `{:ok, workflow}` or `{:error, changeset}`
  - `update/2` returns `{:ok, workflow}` or `{:error, changeset}`
  - `delete/1` returns `{:ok, workflow}` or `{:error, changeset}`
  - `sync_transitions/2` returns `{:ok, [transitions]}` or `{:error, changeset}`

  ## Domain-Specific Errors

  `sync_transitions/2` may return `{:error, changeset}` with validation errors for:
  - Duplicate `to_workflow_id` entries in the transitions list

  ## Preload Strategy

  Preloading is managed by callers. No automatic preloads are applied in this module.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.Workflow

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Project
  alias Sacrum.Repo.Schemas.Workflow
  alias Sacrum.Repo.Schemas.WorkflowTransition
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.SyncHelper

  def insert(%Project{id: project_id, user_id: user_id}, attrs),
    do: insert(project_id, user_id, attrs)

  def insert(project_id, attrs) when is_binary(project_id) and is_map(attrs) do
    %Workflow{project_id: project_id}
    |> Workflow.create_changeset(attrs)
    |> Repo.insert()
    |> Broadcaster.broadcast(:workflow_created, :project)
  end

  defoverridable insert: 2

  def insert(project_id, user_id, attrs) when is_binary(project_id) and is_binary(user_id) do
    %Workflow{project_id: project_id, user_id: user_id}
    |> Workflow.create_changeset(attrs)
    |> Repo.insert()
    |> Broadcaster.broadcast(:workflow_created, :project)
  end

  def update(%Workflow{} = workflow, attrs) do
    workflow
    |> Workflow.update_changeset(attrs)
    |> Repo.update()
    |> Broadcaster.broadcast(:workflow_updated, :project)
  end

  @doc """
  Syncs the transitions for a workflow by diffing incoming list against existing records.
  Deletes removed transitions, inserts new ones. Uses Ecto.Multi for atomicity.

  Each entry in `transition_maps` should have `to_workflow_id` (required),
  and optionally `target_step_id` and `label`.
  """
  def sync_transitions(%Workflow{} = workflow, transition_maps) when is_list(transition_maps) do
    target_ids = Enum.map(transition_maps, & &1["to_workflow_id"])

    if length(target_ids) != length(Enum.uniq(target_ids)) do
      changeset =
        %WorkflowTransition{}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(
          :to_workflow_id,
          "duplicate to_workflow_id in transitions list"
        )

      {:error, changeset}
    else
      do_sync_transitions(workflow, transition_maps)
    end
  end

  defp do_sync_transitions(workflow, transition_maps) do
    existing =
      Repo.WorkflowTransitions.all(
        conditions: [from_workflow_id: workflow.id],
        order_by: [asc: :inserted_at]
      )

    SyncHelper.diff_and_sync(existing, transition_maps, %{
      target_key: :to_workflow_id,
      to_delete_fn: fn existing, incoming_target_ids ->
        Enum.filter(existing, fn t ->
          not MapSet.member?(incoming_target_ids, t.to_workflow_id)
        end)
      end,
      to_insert_fn: fn incoming, existing_by_target ->
        Enum.filter(incoming, fn m ->
          not Map.has_key?(existing_by_target, m["to_workflow_id"])
        end)
      end,
      to_update_fn: fn incoming, existing_by_target ->
        Enum.filter(incoming, fn m ->
          Map.has_key?(existing_by_target, m["to_workflow_id"])
        end)
        |> Enum.map(fn m -> {existing_by_target[m["to_workflow_id"]], m} end)
        |> Enum.filter(fn {existing_rec, m} ->
          existing_rec.label != m["label"] ||
            existing_rec.target_step_id != m["target_step_id"]
        end)
      end,
      build_changeset_fn: fn m ->
        %WorkflowTransition{user_id: workflow.user_id}
        |> WorkflowTransition.create_changeset(Map.merge(m, %{"from_workflow_id" => workflow.id}))
      end,
      build_update_changeset_fn: fn existing_rec, m ->
        existing_rec
        |> Ecto.Changeset.change(%{
          label: m["label"],
          target_step_id: m["target_step_id"]
        })
      end,
      fetch_final_fn: fn ->
        Broadcaster.broadcast_event(workflow, :workflow_updated, :project)

        {:ok,
         Repo.WorkflowTransitions.all(
           conditions: [from_workflow_id: workflow.id],
           order_by: [asc: :inserted_at]
         )}
      end
    })
  end

  def delete(%Workflow{} = workflow) do
    case Repo.delete(workflow) do
      {:ok, deleted} ->
        Broadcaster.broadcast_event(deleted, :workflow_deleted, :project)
        {:ok, deleted}

      error ->
        error
    end
  end
end
