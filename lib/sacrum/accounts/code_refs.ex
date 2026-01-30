defmodule Sacrum.Accounts.CodeRefs do
  @moduledoc """
  User-scoped code reference operations.

  All operations are scoped to a specific user.
  """

  use Sacrum.GenericResource,
    schema: Sacrum.Repo.Schemas.CodeRef,
    preloads: [],
    default_order: [asc: :inserted_at]

  alias Sacrum.Repo.CodeRefs, as: CodeRefsRepo
  alias Sacrum.Repo.Schemas.CodeRef

  @doc """
  Insert a code ref for a task.
  """
  def insert_for_task(user_id, task_id, attrs) when is_binary(user_id) and is_binary(task_id) do
    %CodeRef{task_id: task_id, user_id: user_id}
    |> CodeRef.changeset(attrs)
    |> CodeRefsRepo.insert()
  end

  @doc """
  Insert a code ref for a task section.
  """
  def insert_for_section(user_id, section_id, attrs)
      when is_binary(user_id) and is_binary(section_id) do
    %CodeRef{section_id: section_id, user_id: user_id}
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
