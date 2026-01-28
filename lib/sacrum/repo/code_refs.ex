defmodule Sacrum.Repo.CodeRefs do
  @moduledoc """
  CRUD operations for code references.
  """

  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.CodeRef
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Schemas.TaskSection

  def get(id) do
    case Repo.get(CodeRef, id) do
      nil -> {:error, :not_found}
      ref -> {:ok, ref}
    end
  end

  def get!(id), do: Repo.get!(CodeRef, id)

  def list_for_task(%Task{id: task_id}), do: list_for_task(task_id)

  def list_for_task(task_id) when is_binary(task_id) do
    from(r in CodeRef, where: r.task_id == ^task_id, order_by: [asc: r.inserted_at])
    |> Repo.all()
  end

  def list_for_section(%TaskSection{id: section_id}), do: list_for_section(section_id)

  def list_for_section(section_id) when is_binary(section_id) do
    from(r in CodeRef, where: r.section_id == ^section_id, order_by: [asc: r.inserted_at])
    |> Repo.all()
  end

  def insert_for_task(%Task{id: task_id}, attrs), do: insert_for_task(task_id, attrs)

  def insert_for_task(task_id, attrs) when is_binary(task_id) do
    %CodeRef{task_id: task_id}
    |> CodeRef.changeset(attrs)
    |> Repo.insert()
  end

  def insert_for_section(%TaskSection{id: section_id}, attrs),
    do: insert_for_section(section_id, attrs)

  def insert_for_section(section_id, attrs) when is_binary(section_id) do
    %CodeRef{section_id: section_id}
    |> CodeRef.changeset(attrs)
    |> Repo.insert()
  end

  def delete(%CodeRef{} = ref), do: Repo.delete(ref)
end
