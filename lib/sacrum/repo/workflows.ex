defmodule Sacrum.Repo.Workflows do
  @moduledoc """
  CRUD operations for workflows, scoped to a project.
  """

  import Ecto.Query
  alias Ecto.Multi
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Project
  alias Sacrum.Repo.Schemas.Workflow
  alias Sacrum.Repo.Schemas.WorkflowTransition

  def get(id) do
    case Repo.get(Workflow, id) do
      nil -> {:error, :not_found}
      workflow -> {:ok, workflow}
    end
  end

  def list(%Project{id: project_id}), do: list(project_id)

  def list(project_id) when is_binary(project_id) do
    from(w in Workflow,
      where: w.project_id == ^project_id,
      order_by: [asc: w.display_order, asc: w.inserted_at]
    )
    |> Repo.all()
  end

  def insert(%Project{id: project_id}, attrs), do: insert(project_id, attrs)

  def insert(project_id, attrs) when is_binary(project_id) do
    %Workflow{project_id: project_id}
    |> Workflow.create_changeset(attrs)
    |> Repo.insert()
    |> broadcast(:workflow_created)
  end

  def update(%Workflow{} = workflow, attrs) do
    workflow
    |> Workflow.update_changeset(attrs)
    |> Repo.update()
    |> broadcast(:workflow_updated)
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
    existing = Repo.WorkflowTransitions.list_for_workflow(workflow)

    existing_by_target =
      Map.new(existing, fn t -> {t.to_workflow_id, t} end)

    incoming_target_ids = MapSet.new(transition_maps, & &1["to_workflow_id"])

    to_delete =
      Enum.filter(existing, fn t -> not MapSet.member?(incoming_target_ids, t.to_workflow_id) end)

    to_insert =
      Enum.filter(transition_maps, fn m ->
        not Map.has_key?(existing_by_target, m["to_workflow_id"])
      end)

    to_update =
      Enum.filter(transition_maps, fn m ->
        Map.has_key?(existing_by_target, m["to_workflow_id"])
      end)
      |> Enum.map(fn m -> {existing_by_target[m["to_workflow_id"]], m} end)
      |> Enum.filter(fn {existing_rec, m} ->
        existing_rec.label != m["label"] ||
          existing_rec.target_step_id != m["target_step_id"]
      end)

    multi =
      Multi.new()
      |> delete_transitions(to_delete)
      |> insert_transitions(workflow, to_insert)
      |> update_transitions(to_update)

    case Repo.transaction(multi) do
      {:ok, _} ->
        broadcast_event(workflow, :workflow_updated)
        {:ok, Repo.WorkflowTransitions.list_for_workflow(workflow)}

      {:error, _name, changeset, _changes} ->
        {:error, changeset}
    end
  end

  defp delete_transitions(multi, transitions) do
    Enum.reduce(transitions, multi, fn t, multi ->
      Multi.delete(multi, {:delete, t.id}, t)
    end)
  end

  defp insert_transitions(multi, workflow, maps) do
    Enum.reduce(maps, multi, fn m, multi ->
      changeset =
        %WorkflowTransition{}
        |> WorkflowTransition.create_changeset(Map.merge(m, %{"from_workflow_id" => workflow.id}))

      Multi.insert(multi, {:insert, m["to_workflow_id"]}, changeset)
    end)
  end

  defp update_transitions(multi, pairs) do
    Enum.reduce(pairs, multi, fn {existing_rec, m}, multi ->
      changeset =
        existing_rec
        |> Ecto.Changeset.change(%{
          label: m["label"],
          target_step_id: m["target_step_id"]
        })

      Multi.update(multi, {:update, existing_rec.id}, changeset)
    end)
  end

  def delete(%Workflow{} = workflow) do
    case Repo.delete(workflow) do
      {:ok, deleted} ->
        broadcast_event(deleted, :workflow_deleted)
        {:ok, deleted}

      error ->
        error
    end
  end

  defp broadcast({:ok, workflow}, event) do
    broadcast_event(workflow, event)
    {:ok, workflow}
  end

  defp broadcast({:error, _} = error, _event), do: error

  defp broadcast_event(workflow, event) do
    workflow = Repo.preload(workflow, :project)

    case workflow.project do
      %Project{slug: slug} ->
        apply(SacrumWeb.ProjectChannel, :"broadcast_#{event}", [slug, workflow])

      _ ->
        :ok
    end
  end
end
