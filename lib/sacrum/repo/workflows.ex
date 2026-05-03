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
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.Project
  alias Sacrum.Repo.Schemas.StepExecution
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Schemas.Workflow
  alias Sacrum.Repo.Schemas.WorkflowTransition
  alias Sacrum.Repo.SyncHelper
  alias Sacrum.Repo.UuidPrefixResolver

  @spec find_by_uuid_prefix(String.t(), String.t(), String.t()) ::
          {:ok, Workflow.t()}
          | {:error, :not_found | :invalid_prefix}
          | {:error, {:ambiguous, [String.t()]}}
  def find_by_uuid_prefix(prefix, project_id, user_id) do
    query =
      from(w in Workflow,
        where: w.project_id == ^project_id and w.user_id == ^user_id
      )

    UuidPrefixResolver.find_by_prefix(query, prefix)
  end

  @spec insert(Project.t(), map()) :: {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def insert(%Project{id: project_id, user_id: user_id}, attrs),
    do: insert(project_id, user_id, attrs)

  @spec insert(String.t(), map()) :: {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def insert(project_id, attrs) when is_binary(project_id) and is_map(attrs) do
    %Workflow{project_id: project_id}
    |> Workflow.create_changeset(attrs)
    |> Repo.insert()
    |> Broadcaster.broadcast(:workflow_created, :project)
  end

  defoverridable insert: 2

  @spec insert(String.t(), String.t(), map()) ::
          {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def insert(project_id, user_id, attrs) when is_binary(project_id) and is_binary(user_id) do
    %Workflow{project_id: project_id, user_id: user_id}
    |> Workflow.create_changeset(attrs)
    |> Repo.insert()
    |> Broadcaster.broadcast(:workflow_created, :project)
  end

  @spec update(Workflow.t(), map()) :: {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
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
  @spec sync_transitions(Workflow.t(), list()) :: {:ok, list()} | {:error, Ecto.Changeset.t()}
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
        incoming
        |> Enum.filter(fn m ->
          Map.has_key?(existing_by_target, m["to_workflow_id"])
        end)
        |> Enum.map(fn m -> {existing_by_target[m["to_workflow_id"]], m} end)
        |> Enum.filter(fn {existing_rec, m} ->
          existing_rec.label != m["label"] ||
            existing_rec.target_step_id != m["target_step_id"]
        end)
      end,
      build_changeset_fn: fn m ->
        WorkflowTransition.create_changeset(
          %WorkflowTransition{user_id: workflow.user_id, project_id: workflow.project_id},
          Map.merge(m, %{"from_workflow_id" => workflow.id})
        )
      end,
      build_update_changeset_fn: fn existing_rec, m ->
        Ecto.Changeset.change(existing_rec, %{
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

  @spec delete(Workflow.t()) :: {:ok, Workflow.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Workflow{} = workflow) do
    case Repo.delete(workflow) do
      {:ok, deleted} ->
        Broadcaster.broadcast_event(deleted, :workflow_deleted, :project)
        {:ok, deleted}

      error ->
        error
    end
  end

  @doc """
  Returns all workflows in a project along with batched aggregates needed by the
  pipeline view.

  Returns `{:ok, workflows, %{task_counts_by_step_id: ..., running_counts_by_step_id: ...}}`.
  Aggregates are computed in two grouped queries (task counts by step and level,
  running step-execution counts by step) regardless of how many workflows or steps
  are returned.
  """
  @spec pipeline_summary(String.t(), String.t()) ::
          {:ok, list(Workflow.t()), %{required(atom()) => map()}}
  def pipeline_summary(user_id, project_id) when is_binary(user_id) and is_binary(project_id) do
    workflows =
      Workflow
      |> where([w], w.user_id == ^user_id and w.project_id == ^project_id)
      |> preload([:transitions, workflow_steps: :transitions])
      |> order_by([w], asc: :display_order, asc: :inserted_at)
      |> Repo.all()

    all_step_ids = workflows |> Enum.flat_map(& &1.workflow_steps) |> Enum.map(& &1.id)

    if all_step_ids == [] do
      {:ok, workflows, %{task_counts_by_step_id: %{}, running_counts_by_step_id: %{}}}
    else
      {:ok, workflows,
       %{
         task_counts_by_step_id: task_counts_by_step(project_id, all_step_ids),
         running_counts_by_step_id: running_counts_by_step(project_id, all_step_ids)
       }}
    end
  end

  @level_atoms %{"epic" => :epic, "ticket" => :ticket, "task" => :task}

  defp task_counts_by_step(project_id, step_ids) do
    Task
    |> where([t], t.project_id == ^project_id)
    |> where([t], t.current_step_id in ^step_ids)
    |> where([t], t.archived == false)
    |> group_by([t], [t.current_step_id, t.level])
    |> select([t], {t.current_step_id, t.level, count(t.id)})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {step_id, level, count}, acc ->
      case Map.get(@level_atoms, level) do
        nil ->
          acc

        level_atom ->
          Map.update(acc, step_id, %{level_atom => count}, &Map.put(&1, level_atom, count))
      end
    end)
  end

  defp running_counts_by_step(project_id, step_ids) do
    StepExecution
    |> where([se], se.project_id == ^project_id)
    |> where([se], se.step_id in ^step_ids)
    |> where([se], se.status == "started")
    |> group_by([se], se.step_id)
    |> select([se], {se.step_id, count(se.id)})
    |> Repo.all()
    |> Map.new()
  end
end
