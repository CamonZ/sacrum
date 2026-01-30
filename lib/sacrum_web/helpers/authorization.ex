defmodule SacrumWeb.Helpers.Authorization do
  @moduledoc """
  Shared authorization helpers for controllers.

  This module provides common authorization and lookup functions to avoid
  duplication across controllers. All functions maintain the return value
  contract of {:ok, _} | {:error, _} | :ok for use in with chains.
  """

  alias Sacrum.Repo
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.Schemas.Project
  alias Sacrum.Repo.Schemas.Task

  @doc """
  Find a task by UUID or short_id.

  Returns {:ok, task} or {:error, :not_found}.
  """
  def find_task(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _uuid} -> Tasks.get(id)
      :error -> Tasks.get_by_short_id(id)
    end
  end

  @doc """
  Authorize that the current user owns the project associated with the task.

  Returns :ok if authorized, {:error, :not_found} otherwise.
  The task is preloaded with its project association.
  """
  def authorize_task_owner(%Task{} = task, user) do
    task = Repo.preload(task, :project)

    if task.project && task.project.user_id == user.id do
      :ok
    else
      {:error, :not_found}
    end
  end

  @doc """
  Authorize that the current user owns the project associated with an execution.

  The execution is preloaded with workflow: :project association.
  Returns :ok if authorized, {:error, :not_found} otherwise.
  """
  def authorize_execution_owner(execution, user) do
    execution = Repo.preload(execution, workflow: :project)

    if execution.workflow && execution.workflow.project &&
         execution.workflow.project.user_id == user.id do
      :ok
    else
      {:error, :not_found}
    end
  end

  @doc """
  Authorize that the current user owns the given project.

  Returns {:ok, project} if authorized, {:error, :not_found} otherwise.
  """
  def authorize_project(project_id, user) do
    with {:ok, %Project{} = project} <- Projects.get(project_id),
         true <- project.user_id == user.id do
      {:ok, project}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end
end
