defmodule Sacrum.Accounts.CodeRefs do
  @moduledoc """
  User-scoped code reference operations.

  All operations are scoped to a specific user.
  """

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.CodeRefs,
    preloads: [],
    default_order: [asc: :inserted_at]

  alias Sacrum.Accounts.Tasks
  alias Sacrum.Repo.CodeRefs, as: CodeRefsRepo
  alias Sacrum.Repo.Schemas.CodeRef

  @doc """
  Insert a code ref for a task.
  """
  @spec insert_for_task(String.t(), map()) :: {:ok, CodeRef.t()} | {:error, Ecto.Changeset.t()}
  def insert_for_task(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    task_id = Map.get(attrs, "task_id") || Map.get(attrs, :task_id)
    project_id = Map.get(attrs, "project_id") || Map.get(attrs, :project_id)

    %CodeRef{task_id: task_id, project_id: project_id, user_id: user_id}
    |> CodeRef.changeset(attrs)
    |> CodeRefsRepo.insert()
  end

  @doc """
  Insert a code ref for a task section.
  """
  @spec insert_for_section(String.t(), map()) :: {:ok, CodeRef.t()} | {:error, Ecto.Changeset.t()}
  def insert_for_section(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    section_id = Map.get(attrs, "section_id") || Map.get(attrs, :section_id)
    project_id = Map.get(attrs, "project_id") || Map.get(attrs, :project_id)

    %CodeRef{section_id: section_id, project_id: project_id, user_id: user_id}
    |> CodeRef.changeset(attrs)
    |> CodeRefsRepo.insert()
  end

  @doc """
  Delete a code ref.
  """
  @spec delete(CodeRef.t()) :: {:ok, CodeRef.t()} | {:error, Ecto.Changeset.t()}
  def delete(%CodeRef{} = ref) do
    CodeRefsRepo.delete(ref)
  end

  @doc """
  Delete all code refs for a task.

  This is a user-scoped operation that verifies the user owns the task before deleting.
  Returns `{:ok, deleted_refs}` if successful, or `{:error, :not_found}` if the task doesn't exist.
  """
  @spec delete_task_refs(String.t(), String.t()) :: {:ok, [CodeRef.t()]} | {:error, :not_found}
  def delete_task_refs(user_id, task_id) when is_binary(user_id) and is_binary(task_id) do
    case Tasks.find(user_id, task_id) do
      {:ok, _task} ->
        CodeRefsRepo.delete_by_task(task_id)

      {:error, _} ->
        {:error, :not_found}
    end
  end
end
