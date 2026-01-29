defmodule SacrumWeb.TaskJSON do
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.TaskHierarchy
  alias Sacrum.Repo.TaskDependencies

  def index(%{tasks: tasks}) do
    %{data: for(task <- tasks, do: data(task))}
  end

  def show(%{task: task}) do
    %{data: data(task)}
  end

  def tree(%{tree: tree}) do
    %{data: tree_data(tree)}
  end

  defp tree_data(%{task: task, children: children}) do
    data(task)
    |> Map.put(:children, Enum.map(children, &tree_data/1))
  end

  defp data(%Task{} = task) do
    %{
      id: task.id,
      short_id: task.short_id,
      project_id: task.project_id,
      title: task.title,
      description: task.description,
      level: task.level,
      priority: task.priority,
      tags: task.tags,
      workflow_id: task.workflow_id,
      current_step_id: task.current_step_id,
      needs_human_review: task.needs_human_review,
      review_comment: task.review_comment,
      rejection_reason: task.rejection_reason,
      revision_feedback: task.revision_feedback,
      parent_id: get_parent_id(task),
      dependency_ids: get_dependency_ids(task),
      started_at: task.started_at,
      completed_at: task.completed_at,
      inserted_at: task.inserted_at,
      updated_at: task.updated_at
    }
  end

  defp get_parent_id(task) do
    case TaskHierarchy.get_parent(task) do
      {:ok, parent} -> parent.id
      {:error, :not_found} -> nil
    end
  end

  defp get_dependency_ids(task) do
    task
    |> TaskDependencies.get_direct_blockers()
    |> Enum.map(& &1.id)
  end

  def blockers(%{tasks: tasks}) do
    %{data: for(task <- tasks, do: blocker_data(task))}
  end

  defp blocker_data(%Task{} = task) do
    %{
      id: task.id,
      short_id: task.short_id,
      title: task.title,
      level: task.level,
      completed_at: task.completed_at
    }
  end
end
