defmodule SacrumWeb.TaskRelationshipJSON do
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
      title: task.title,
      level: task.level,
      completed_at: task.completed_at
    }
  end
end
