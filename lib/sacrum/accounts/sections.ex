defmodule Sacrum.Accounts.Sections do
  @moduledoc """
  User-scoped task section operations.

  All operations are scoped to a specific user.
  """

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Schemas.TaskSection
  alias Sacrum.Repo.TaskSections

  @doc """
  Get a section by ID, scoped to a user.
  """
  @spec get_by(String.t(), keyword()) :: {:ok, TaskSection.t()} | {:error, :not_found}
  def get_by(user_id, conditions: conditions) when is_binary(user_id) do
    case TaskSections.get_by(conditions) do
      {:ok, %TaskSection{} = section} ->
        section = Repo.preload(section, :task)

        if section.task.user_id == user_id do
          {:ok, section}
        else
          {:error, :not_found}
        end

      error ->
        error
    end
  end

  @doc """
  Insert a section for a task.
  Extracts task_id and project_id from attrs.
  """
  @spec insert(String.t(), map()) :: {:ok, TaskSection.t()} | {:error, Ecto.Changeset.t()}
  def insert(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    task_id = Map.get(attrs, "task_id") || Map.get(attrs, :task_id)
    project_id = Map.get(attrs, "project_id") || Map.get(attrs, :project_id)

    %TaskSection{task_id: task_id, project_id: project_id, user_id: user_id}
    |> TaskSection.changeset(attrs)
    |> TaskSections.insert()
  end

  @doc """
  Update a section.
  """
  @spec update(TaskSection.t(), map()) :: {:ok, TaskSection.t()} | {:error, Ecto.Changeset.t()}
  def update(%TaskSection{} = section, attrs) do
    TaskSections.update(section, attrs)
  end

  @doc """
  Upsert a section for a task.

  Single-instance section types replace the existing section for the task.
  Multi-instance section types insert a new section.
  """
  @spec upsert_for_task(String.t(), Task.t(), map()) ::
          {:ok, TaskSection.t()} | {:error, Ecto.Changeset.t()}
  def upsert_for_task(user_id, %Task{} = task, attrs) when is_binary(user_id) and is_map(attrs) do
    if task.user_id == user_id do
      attrs =
        attrs
        |> Map.put(:task_id, task.id)
        |> Map.put(:project_id, task.project_id)

      TaskSections.upsert(task, attrs)
    else
      {:error, :not_found}
    end
  end

  @doc """
  Delete a section.
  """
  @spec delete(TaskSection.t()) :: {:ok, TaskSection.t()} | {:error, Ecto.Changeset.t()}
  def delete(%TaskSection{} = section) do
    TaskSections.delete(section)
  end
end
