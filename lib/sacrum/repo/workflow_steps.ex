defmodule Sacrum.Repo.WorkflowSteps do
  @moduledoc """
  CRUD operations for workflow steps.

  ## Error Contract

  - `get/1` returns `{:ok, step}` or `{:error, :not_found}`
  - `get!/1` returns step or raises
  - `get_by/1` returns `{:ok, step}` or `{:error, :not_found}`
  - `all/0` returns `[step]`
  - `insert/1` returns `{:ok, step}` or `{:error, changeset}`
  - `update/1` returns `{:ok, step}` or `{:error, changeset}`
  - `delete/1` returns `{:ok, step}` or `{:error, changeset}`
  - `sync_transitions/2` returns `{:ok, [transitions]}` or `{:error, changeset}` or `{:error, atom}`

  ## Domain-Specific Errors

  `sync_transitions/2` may return `{:error, atom}` for:
  - `:duplicate_to_step_ids` - when transition list has duplicate target steps
  - `:different_workflows` - when target steps belong to different workflows

  ## Preload Strategy

  Preloading is managed by callers. No automatic preloads are applied in this module.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.WorkflowStep

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.StepTransition
  alias Sacrum.Repo.Schemas.Workflow
  alias Sacrum.Repo.Schemas.WorkflowStep
  alias Sacrum.Repo.SyncHelper

  @doc """
  Insert a new workflow step. Accepts Workflow struct (with or without user_id).
  """
  def insert(%Workflow{id: workflow_id, project_id: project_id, user_id: user_id}, attrs)
      when is_binary(user_id) do
    insert(workflow_id, project_id, user_id, attrs)
  end

  def insert(%Workflow{id: workflow_id, project_id: project_id}, attrs) do
    %WorkflowStep{workflow_id: workflow_id, project_id: project_id}
    |> WorkflowStep.create_changeset(attrs)
    |> Repo.insert()
    |> Broadcaster.broadcast(:step_created, workflow: :project)
  end

  def insert(workflow_id, attrs) when is_binary(workflow_id) and is_map(attrs) do
    %WorkflowStep{workflow_id: workflow_id}
    |> WorkflowStep.create_changeset(attrs)
    |> Repo.insert()
    |> Broadcaster.broadcast(:step_created, workflow: :project)
  end

  defoverridable insert: 2

  def insert(workflow_id, user_id, attrs)
      when is_binary(workflow_id) and is_binary(user_id) and is_map(attrs) do
    %WorkflowStep{workflow_id: workflow_id, user_id: user_id}
    |> WorkflowStep.create_changeset(attrs)
    |> Repo.insert()
    |> Broadcaster.broadcast(:step_created, workflow: :project)
  end

  def insert(workflow_id, project_id, user_id, attrs)
      when is_binary(workflow_id) and is_binary(project_id) and is_binary(user_id) do
    %WorkflowStep{workflow_id: workflow_id, project_id: project_id, user_id: user_id}
    |> WorkflowStep.create_changeset(attrs)
    |> Repo.insert()
    |> Broadcaster.broadcast(:step_created, workflow: :project)
  end

  def update(%WorkflowStep{} = step, attrs) do
    step
    |> WorkflowStep.update_changeset(attrs)
    |> Repo.update()
    |> Broadcaster.broadcast(:step_updated, workflow: :project)
  end

  @doc """
  Syncs outgoing transitions for a step. Accepts a list of maps with
  `to_step_id` and optional `label`. Diffs against existing StepTransition
  records where from_step_id matches, adding new ones and removing absent ones.

  Returns `{:ok, [%StepTransition{}]}` or `{:error, reason}`.
  """
  def sync_transitions(%WorkflowStep{} = step, transitions) when is_list(transitions) do
    step = Repo.preload(step, :workflow)

    with :ok <- validate_no_duplicate_targets(transitions),
         :ok <- validate_same_workflow(step, transitions) do
      existing =
        Repo.all(from(t in StepTransition, where: t.from_step_id == ^step.id))

      SyncHelper.diff_and_sync(existing, transitions, %{
        target_key: :to_step_id,
        to_delete_fn: fn existing, incoming_target_ids ->
          Enum.filter(existing, fn t -> not MapSet.member?(incoming_target_ids, t.to_step_id) end)
        end,
        to_insert_fn: fn incoming, existing_by_target ->
          Enum.filter(incoming, fn t ->
            to_id = to_step_id(t)
            not Map.has_key?(existing_by_target, to_id)
          end)
        end,
        to_update_fn: fn _incoming, _existing_by_target ->
          # No updates for step transitions - they're created with just from/to, no other mutable fields
          []
        end,
        build_changeset_fn: fn t ->
          to_id = to_step_id(t)

          StepTransition.create_changeset(
            %StepTransition{user_id: step.user_id, project_id: step.project_id},
            %{
              from_step_id: step.id,
              to_step_id: to_id,
              label: label_for(t)
            }
          )
        end,
        build_update_changeset_fn: fn _existing, _map ->
          # No-op for step transitions
          nil
        end,
        fetch_final_fn: fn ->
          updated =
            Repo.all(
              from(t in StepTransition,
                where: t.from_step_id == ^step.id,
                order_by: [asc: t.inserted_at]
              )
            )

          {:ok, updated}
        end
      })
    end
  end

  # sync_transitions helpers

  defp to_step_id(%{"to_step_id" => id}), do: id
  defp to_step_id(%{to_step_id: id}), do: id

  defp label_for(%{"label" => label}), do: label
  defp label_for(%{label: label}), do: label
  defp label_for(_), do: nil

  defp validate_no_duplicate_targets(transitions) do
    ids = Enum.map(transitions, &to_step_id/1)

    if length(ids) == length(Enum.uniq(ids)) do
      :ok
    else
      {:error, :duplicate_to_step_ids}
    end
  end

  defp validate_same_workflow(%WorkflowStep{workflow_id: wf_id}, transitions) do
    to_ids = Enum.map(transitions, &to_step_id/1)

    if to_ids == [] do
      :ok
    else
      count =
        Repo.aggregate(
          from(s in WorkflowStep,
            where: s.id in ^to_ids and s.workflow_id == ^wf_id
          ),
          :count
        )

      if count == length(to_ids) do
        :ok
      else
        {:error, :different_workflows}
      end
    end
  end

  def delete(%WorkflowStep{} = step) do
    case Repo.delete(step) do
      {:ok, deleted} ->
        Broadcaster.broadcast_event(deleted, :step_deleted, workflow: :project)
        {:ok, deleted}

      error ->
        error
    end
  end
end
