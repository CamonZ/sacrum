defmodule SacrumWeb.TaskJSON do
  alias Sacrum.Repo.Schemas.Task

  def index(%{tasks: tasks}) do
    %{data: for(task <- tasks, do: data(task))}
  end

  def show(%{task: task}) do
    %{data: data(task)}
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
      started_at: task.started_at,
      completed_at: task.completed_at,
      inserted_at: task.inserted_at,
      updated_at: task.updated_at
    }
  end
end
