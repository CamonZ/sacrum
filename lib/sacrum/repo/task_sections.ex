defmodule Sacrum.Repo.TaskSections do
  @moduledoc """
  CRUD operations for task sections.

  ## Error Contract

  - `get/1` returns `{:ok, section}` or `{:error, :not_found}`
  - `get!/1` returns section or raises
  - `get_by/1` returns `{:ok, section}` or `{:error, :not_found}`
  - `all/0` returns `[section]`
  - `insert/1` returns `{:ok, section}` or `{:error, changeset}`
  - `update/1` returns `{:ok, section}` or `{:error, changeset}`
  - `delete/1` returns `{:ok, section}` or `{:error, changeset}`

  ## Preload Strategy

  Preloading is managed by callers. No automatic preloads are applied in this module.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.TaskSection

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Schemas.TaskSection

  def insert(%Task{id: task_id, user_id: user_id}, attrs) when is_binary(user_id) do
    insert(task_id, user_id, attrs)
  end

  def insert(%Task{id: task_id, user_id: user_id}, attrs) when user_id != nil do
    insert(task_id, user_id, attrs)
  end

  def insert(%Task{id: task_id}, attrs) do
    %TaskSection{task_id: task_id}
    |> TaskSection.changeset(attrs)
    |> Repo.insert()
    |> Broadcaster.broadcast_section(:section_created)
  end

  def insert(task_id, attrs) when is_binary(task_id) and is_map(attrs) do
    %TaskSection{task_id: task_id}
    |> TaskSection.changeset(attrs)
    |> Repo.insert()
    |> Broadcaster.broadcast_section(:section_created)
  end

  def insert(task_id, user_id, attrs) when is_binary(task_id) and is_binary(user_id) do
    %TaskSection{task_id: task_id, user_id: user_id}
    |> TaskSection.changeset(attrs)
    |> Repo.insert()
    |> Broadcaster.broadcast_section(:section_created)
  end

  def update(%TaskSection{} = section, attrs) do
    section
    |> TaskSection.changeset(attrs)
    |> Repo.update()
    |> Broadcaster.broadcast_section(:section_updated)
  end

  def delete(%TaskSection{} = section) do
    Repo.delete(section)
    |> Broadcaster.broadcast_section(:section_deleted)
  end
end
