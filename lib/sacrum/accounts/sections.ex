defmodule Sacrum.Accounts.Sections do
  @moduledoc """
  User-scoped task section operations.

  All operations are scoped to a specific user.
  """

  alias Sacrum.Repo
  alias Sacrum.Repo.TaskSections
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Schemas.TaskSection

  @doc """
  Get a section by ID, scoped to a user.
  """
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
  """
  def insert(%Task{id: task_id, user_id: user_id}, attrs) do
    TaskSections.insert(task_id, user_id, attrs)
  end

  @doc """
  Update a section.
  """
  def update(%TaskSection{} = section, attrs) do
    TaskSections.update(section, attrs)
  end

  @doc """
  Delete a section.
  """
  def delete(%TaskSection{} = section) do
    TaskSections.delete(section)
  end
end
