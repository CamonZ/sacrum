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
    |> CodeRef.changeset(assign_task_order_index(task_id, attrs))
    |> Repo.insert()
  end

  @spec insert_for_task(String.t(), String.t(), map()) ::
          {:ok, CodeRef.t()} | {:error, Ecto.Changeset.t()}
  def insert_for_task(task_id, project_id, attrs)
      when is_binary(task_id) and is_binary(project_id) and is_map(attrs) do
    %CodeRef{task_id: task_id, project_id: project_id}
    |> CodeRef.changeset(assign_task_order_index(task_id, attrs))
    |> Repo.insert()
  end

  def insert_for_task(task_id, user_id, attrs)
      when is_binary(task_id) and is_binary(user_id) and is_map(attrs) do
    %CodeRef{task_id: task_id, user_id: user_id}
    |> CodeRef.changeset(assign_task_order_index(task_id, attrs))
    |> Repo.insert()
  end

  @spec insert_for_task(String.t(), String.t(), String.t(), map()) ::
          {:ok, CodeRef.t()} | {:error, Ecto.Changeset.t()}
  def insert_for_task(task_id, project_id, user_id, attrs)
      when is_binary(task_id) and is_binary(project_id) and is_binary(user_id) do
    %CodeRef{task_id: task_id, project_id: project_id, user_id: user_id}
    |> CodeRef.changeset(assign_task_order_index(task_id, attrs))
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
    |> CodeRef.changeset(assign_section_order_index(section_id, attrs))
    |> Repo.insert()
  end

  @spec insert_for_section(String.t(), String.t(), map()) ::
          {:ok, CodeRef.t()} | {:error, Ecto.Changeset.t()}
  def insert_for_section(section_id, project_id, attrs)
      when is_binary(section_id) and is_binary(project_id) and is_map(attrs) do
    %CodeRef{section_id: section_id, project_id: project_id}
    |> CodeRef.changeset(assign_section_order_index(section_id, attrs))
    |> Repo.insert()
  end

  def insert_for_section(section_id, user_id, attrs)
      when is_binary(section_id) and is_binary(user_id) and is_map(attrs) do
    %CodeRef{section_id: section_id, user_id: user_id}
    |> CodeRef.changeset(assign_section_order_index(section_id, attrs))
    |> Repo.insert()
  end

  @spec insert_for_section(String.t(), String.t(), String.t(), map()) ::
          {:ok, CodeRef.t()} | {:error, Ecto.Changeset.t()}
  def insert_for_section(section_id, project_id, user_id, attrs)
      when is_binary(section_id) and is_binary(project_id) and is_binary(user_id) do
    %CodeRef{section_id: section_id, project_id: project_id, user_id: user_id}
    |> CodeRef.changeset(assign_section_order_index(section_id, attrs))
    |> Repo.insert()
  end

  @doc """
  Delete all code refs associated with a task.

  Returns `{:ok, deleted_refs}` where deleted_refs is a list of the deleted code refs.
  """
  @spec delete_by_task(String.t()) :: {:ok, [CodeRef.t()]}
  def delete_by_task(task_id) when is_binary(task_id) do
    {_count, refs} =
      Repo.delete_all(from(cr in CodeRef, where: cr.task_id == ^task_id, select: cr))

    {:ok, refs}
  end

  @doc """
  Replaces all code refs for a task in one transaction.
  """
  @spec set_for_task(Task.t(), [map()]) :: {:ok, [CodeRef.t()]} | {:error, Ecto.Changeset.t()}
  def set_for_task(%Task{} = task, refs) when is_list(refs) do
    result =
      Repo.transaction(fn ->
        Repo.delete_all(from(cr in CodeRef, where: cr.task_id == ^task.id))

        case insert_ordered_task_refs(task, refs) do
          {:ok, inserted_refs} -> inserted_refs
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, inserted_refs} -> {:ok, inserted_refs}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
    end
  end

  defp insert_ordered_task_refs(task, refs) do
    refs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {attrs, index}, {:ok, inserted_refs} ->
      attrs = normalize_order_index(attrs, index)

      case insert_for_task(task, attrs) do
        {:ok, ref} -> {:cont, {:ok, [ref | inserted_refs]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
    |> case do
      {:ok, inserted_refs} -> {:ok, Enum.reverse(inserted_refs)}
      error -> error
    end
  end

  defp normalize_order_index(attrs, index) do
    explicit_order = Map.get(attrs, :order, Map.get(attrs, "order"))
    order_index_key = order_index_key(attrs)

    attrs
    |> Map.drop([:order, "order"])
    |> Map.put_new(order_index_key, explicit_order || index)
  end

  defp order_index_key(attrs) do
    if Enum.any?(attrs, fn {key, _value} -> is_binary(key) end) do
      "order_index"
    else
      :order_index
    end
  end

  defp assign_task_order_index(task_id, attrs) do
    assign_order_index(attrs, fn -> next_order_index(:task_id, task_id) end)
  end

  defp assign_section_order_index(section_id, attrs) do
    assign_order_index(attrs, fn -> next_order_index(:section_id, section_id) end)
  end

  defp assign_order_index(attrs, next_order_fn) do
    if order_index_present?(attrs) do
      attrs
    else
      normalize_order_index(attrs, next_order_fn.())
    end
  end

  defp order_index_present?(attrs) do
    Map.has_key?(attrs, :order_index) or Map.has_key?(attrs, "order_index")
  end

  defp next_order_index(parent_field, parent_id) do
    max_order =
      Repo.one(
        from ref in CodeRef,
          where: field(ref, ^parent_field) == ^parent_id,
          select: max(ref.order_index)
      )

    case max_order do
      nil -> 0
      order -> order + 1
    end
  end
end
