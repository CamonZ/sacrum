defmodule Sacrum.Repo.WorkflowSteps do
  @moduledoc """
  CRUD operations for workflow steps, scoped to a workflow.
  """

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Workflow
  alias Sacrum.Repo.Schemas.WorkflowStep
  alias Sacrum.Repo.Schemas.StepTransition
  alias Sacrum.Repo.Broadcaster

  def get(id) do
    case Repo.get(WorkflowStep, id) do
      nil -> {:error, :not_found}
      step -> {:ok, step}
    end
  end

  def list(%Workflow{id: workflow_id}), do: list(workflow_id)

  def list(workflow_id) when is_binary(workflow_id) do
    from(s in WorkflowStep,
      where: s.workflow_id == ^workflow_id,
      order_by: [asc: s.step_order, asc: s.inserted_at]
    )
    |> Repo.all()
  end

  def insert(%Workflow{id: workflow_id}, attrs), do: insert(workflow_id, attrs)

  def insert(workflow_id, attrs) when is_binary(workflow_id) do
    %WorkflowStep{workflow_id: workflow_id}
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
        from(t in StepTransition, where: t.from_step_id == ^step.id)
        |> Repo.all()

      existing_by_to = Map.new(existing, &{&1.to_step_id, &1})

      desired_to_ids =
        MapSet.new(transitions, &to_step_id/1)

      existing_to_ids =
        MapSet.new(existing, & &1.to_step_id)

      to_add = MapSet.difference(desired_to_ids, existing_to_ids)
      to_remove = MapSet.difference(existing_to_ids, desired_to_ids)

      Ecto.Multi.new()
      |> delete_removed_transitions(to_remove, existing_by_to)
      |> insert_new_transitions(step, transitions, to_add)
      |> Repo.transaction()
      |> case do
        {:ok, _changes} ->
          updated =
            from(t in StepTransition,
              where: t.from_step_id == ^step.id,
              order_by: [asc: t.inserted_at]
            )
            |> Repo.all()

          {:ok, updated}

        {:error, _op, changeset, _changes} ->
          {:error, changeset}
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
        from(s in WorkflowStep,
          where: s.id in ^to_ids and s.workflow_id == ^wf_id
        )
        |> Repo.aggregate(:count)

      if count == length(to_ids) do
        :ok
      else
        {:error, :different_workflows}
      end
    end
  end

  defp delete_removed_transitions(multi, to_remove, existing_by_to) do
    Enum.reduce(to_remove, multi, fn to_id, acc ->
      transition = Map.fetch!(existing_by_to, to_id)
      Ecto.Multi.delete(acc, {:delete, to_id}, transition)
    end)
  end

  defp insert_new_transitions(multi, step, transitions, to_add) do
    transitions
    |> Enum.filter(fn t -> MapSet.member?(to_add, to_step_id(t)) end)
    |> Enum.reduce(multi, fn t, acc ->
      to_id = to_step_id(t)

      changeset =
        StepTransition.create_changeset(%StepTransition{}, %{
          from_step_id: step.id,
          to_step_id: to_id,
          label: label_for(t)
        })

      Ecto.Multi.insert(acc, {:insert, to_id}, changeset)
    end)
  end
end
