defmodule Sacrum.Repo.CodeRefs do
  @moduledoc """
  CRUD operations for code references.

  ## Error Contract

  - `get/1` returns `{:ok, ref}` or `{:error, :not_found}`
  - `get!/1` returns ref or raises
  - `get_by/1` returns `{:ok, ref}` or `{:error, :not_found}`
  - `all/0` returns `[ref]`
  - `insert/1` returns `{:ok, ref}` or `{:error, changeset}`
  - `delete/1` returns `{:ok, ref}` or `{:error, changeset}`

  ## Preload Strategy

  Preloading is managed by callers. No automatic preloads are applied in this module.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.CodeRef

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.CodeRef
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Schemas.TaskSection

  @spec insert_for_task(Task.t(), map()) :: {:ok, CodeRef.t()} | {:error, Ecto.Changeset.t()}
  def insert_for_task(%Task{id: task_id, project_id: project_id, user_id: user_id}, attrs)
      when is_binary(user_id),
      do: insert_for_task(task_id, project_id, user_id, attrs)

  def insert_for_task(%Task{id: task_id, project_id: project_id}, attrs),
    do: insert_for_task(task_id, project_id, attrs)

  @spec insert_for_task(String.t(), map()) :: {:ok, CodeRef.t()} | {:error, Ecto.Changeset.t()}
  def insert_for_task(task_id, attrs) when is_binary(task_id) and is_map(attrs) do
    %CodeRef{task_id: task_id}
    |> CodeRef.changeset(attrs)
    |> Repo.insert()
  end

  @spec insert_for_task(String.t(), String.t(), map()) ::
          {:ok, CodeRef.t()} | {:error, Ecto.Changeset.t()}
  def insert_for_task(task_id, project_id, attrs)
      when is_binary(task_id) and is_binary(project_id) and is_map(attrs) do
    %CodeRef{task_id: task_id, project_id: project_id}
    |> CodeRef.changeset(attrs)
    |> Repo.insert()
  end

  def insert_for_task(task_id, user_id, attrs)
      when is_binary(task_id) and is_binary(user_id) and is_map(attrs) do
    %CodeRef{task_id: task_id, user_id: user_id}
    |> CodeRef.changeset(attrs)
    |> Repo.insert()
  end

  @spec insert_for_task(String.t(), String.t(), String.t(), map()) ::
          {:ok, CodeRef.t()} | {:error, Ecto.Changeset.t()}
  def insert_for_task(task_id, project_id, user_id, attrs)
      when is_binary(task_id) and is_binary(project_id) and is_binary(user_id) do
    %CodeRef{task_id: task_id, project_id: project_id, user_id: user_id}
    |> CodeRef.changeset(attrs)
    |> Repo.insert()
  end

  @spec insert_for_section(TaskSection.t(), map()) ::
          {:ok, CodeRef.t()} | {:error, Ecto.Changeset.t()}
  def insert_for_section(
        %TaskSection{id: section_id, project_id: project_id, user_id: user_id},
        attrs
      )
      when is_binary(user_id),
      do: insert_for_section(section_id, project_id, user_id, attrs)

  def insert_for_section(%TaskSection{id: section_id, project_id: project_id}, attrs),
    do: insert_for_section(section_id, project_id, attrs)

  @spec insert_for_section(String.t(), map()) :: {:ok, CodeRef.t()} | {:error, Ecto.Changeset.t()}
  def insert_for_section(section_id, attrs) when is_binary(section_id) and is_map(attrs) do
    %CodeRef{section_id: section_id}
    |> CodeRef.changeset(attrs)
    |> Repo.insert()
  end

  @spec insert_for_section(String.t(), String.t(), map()) ::
          {:ok, CodeRef.t()} | {:error, Ecto.Changeset.t()}
  def insert_for_section(section_id, project_id, attrs)
      when is_binary(section_id) and is_binary(project_id) and is_map(attrs) do
    %CodeRef{section_id: section_id, project_id: project_id}
    |> CodeRef.changeset(attrs)
    |> Repo.insert()
  end

  def insert_for_section(section_id, user_id, attrs)
      when is_binary(section_id) and is_binary(user_id) and is_map(attrs) do
    %CodeRef{section_id: section_id, user_id: user_id}
    |> CodeRef.changeset(attrs)
    |> Repo.insert()
  end

  @spec insert_for_section(String.t(), String.t(), String.t(), map()) ::
          {:ok, CodeRef.t()} | {:error, Ecto.Changeset.t()}
  def insert_for_section(section_id, project_id, user_id, attrs)
      when is_binary(section_id) and is_binary(project_id) and is_binary(user_id) do
    %CodeRef{section_id: section_id, project_id: project_id, user_id: user_id}
    |> CodeRef.changeset(attrs)
    |> Repo.insert()
  end
end
