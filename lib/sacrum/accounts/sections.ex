defmodule Sacrum.Accounts.Sections do
  @moduledoc """
  User-scoped task section operations.

  All operations are scoped to a specific user.
  """

  alias Sacrum.Repo
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.TaskSection
  alias Sacrum.Repo.TaskSections

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
  Extracts task_id and project_id from attrs.
  """
  def insert(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    task_id = Map.get(attrs, "task_id") || Map.get(attrs, :task_id)
    project_id = Map.get(attrs, "project_id") || Map.get(attrs, :project_id)

    %TaskSection{task_id: task_id, project_id: project_id, user_id: user_id}
    |> TaskSection.changeset(attrs)
    |> Repo.insert()
    |> Broadcaster.broadcast_section(:section_created)
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
