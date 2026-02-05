defmodule Sacrum.Accounts.CodeRefs do
  @moduledoc """
  User-scoped code reference operations.

  All operations are scoped to a specific user.
  """

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.CodeRefs,
    preloads: [],
    default_order: [asc: :inserted_at]

  alias Sacrum.Repo.CodeRefs, as: CodeRefsRepo
  alias Sacrum.Repo.Schemas.CodeRef

  @doc """
  Insert a code ref for a task.
  """
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
  def delete(%CodeRef{} = ref) do
    CodeRefsRepo.delete(ref)
  end
end
