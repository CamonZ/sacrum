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

  alias Ecto.Changeset
  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Schemas.TaskSection

  @order_retry_count 1
  @single_instance_section_types ~w(goal context current_behavior desired_behavior)

  @spec insert(Changeset.t()) :: {:ok, TaskSection.t()} | {:error, Changeset.t()}
  def insert(%Changeset{} = changeset) do
    if auto_order_required?(changeset) and order_scope_present?(changeset) do
      insert_with_order_retry(changeset, @order_retry_count)
    else
      Repo.insert(changeset)
    end
  end

  @spec insert(Task.t(), map()) :: {:ok, TaskSection.t()} | {:error, Ecto.Changeset.t()}
  def insert(%Task{id: task_id, project_id: project_id, user_id: user_id}, attrs) do
    %TaskSection{task_id: task_id, project_id: project_id, user_id: user_id}
    |> TaskSection.changeset(attrs)
    |> insert()
  end

  @spec update(TaskSection.t(), map()) :: {:ok, TaskSection.t()} | {:error, Ecto.Changeset.t()}
  def update(%TaskSection{} = section, attrs) do
    section
    |> TaskSection.changeset(attrs)
    |> Repo.update()
  end

  @spec upsert(Task.t(), map()) :: {:ok, TaskSection.t()} | {:error, Ecto.Changeset.t()}
  def upsert(%Task{} = task, attrs) do
    section_type = Map.get(attrs, :section_type, Map.get(attrs, "section_type"))

    if single_instance_section_type?(section_type) do
      upsert_single_instance(task, attrs, section_type)
    else
      insert(task, attrs)
    end
  end

  @spec delete(TaskSection.t()) :: {:ok, TaskSection.t()} | {:error, Ecto.Changeset.t()}
  def delete(%TaskSection{} = section) do
    Repo.delete(section)
  end

  @spec artifact_link_subject(TaskSection.t(), atom() | String.t()) :: map()
  def artifact_link_subject(%TaskSection{} = section, relationship_kind)
      when is_atom(relationship_kind) or is_binary(relationship_kind) do
    %{
      subject_type: "task_section",
      subject_id: section.id,
      relationship_kind: to_string(relationship_kind)
    }
  end

  defp insert_with_order_retry(%Changeset{} = changeset, retries_remaining) do
    case insert_with_next_order(changeset) do
      {:ok, section} ->
        {:ok, section}

      {:error, %Changeset{} = error_changeset} = error ->
        if retries_remaining > 0 and unique_section_order_error?(error_changeset) do
          insert_with_order_retry(changeset, retries_remaining - 1)
        else
          error
        end
    end
  end

  defp insert_with_next_order(%Changeset{} = changeset) do
    with_section_order_transaction(fn ->
      lock_task_for_section_order(changeset)

      changeset
      |> assign_next_section_order()
      |> Repo.insert(mode: :savepoint)
    end)
  end

  defp upsert_single_instance(task, attrs, section_type) do
    with_section_order_transaction(fn ->
      lock_task(task.id)

      case get_single_instance_section(task.id, section_type) do
        nil -> insert(task, attrs)
        section -> __MODULE__.update(section, attrs)
      end
    end)
  end

  defp with_section_order_transaction(fun) when is_function(fun, 0) do
    if Repo.in_transaction?() do
      fun.()
    else
      fun
      |> run_section_order_transaction()
      |> unwrap_section_order_transaction()
    end
  end

  defp run_section_order_transaction(fun) when is_function(fun, 0) do
    Repo.transaction(fn -> commit_or_rollback(fun.()) end)
  end

  defp commit_or_rollback({:ok, section}), do: section

  defp commit_or_rollback({:error, %Changeset{} = error_changeset}),
    do: Repo.rollback(error_changeset)

  defp unwrap_section_order_transaction({:ok, section}), do: {:ok, section}

  defp unwrap_section_order_transaction({:error, %Changeset{} = error_changeset}),
    do: {:error, error_changeset}

  defp auto_order_required?(%Changeset{} = changeset) do
    is_nil(Changeset.get_field(changeset, :section_order))
  end

  defp order_scope_present?(%Changeset{} = changeset) do
    is_binary(Changeset.get_field(changeset, :task_id)) and
      is_binary(Changeset.get_field(changeset, :section_type))
  end

  defp lock_task_for_section_order(%Changeset{} = changeset) do
    task_id = Changeset.get_field(changeset, :task_id)
    lock_task(task_id)
  end

  defp lock_task(task_id) do
    Repo.one(
      from task in Task,
        where: task.id == ^task_id,
        lock: "FOR UPDATE",
        select: task.id
    )

    :ok
  end

  defp get_single_instance_section(task_id, section_type) do
    Repo.one(
      from section in query(),
        where: section.task_id == ^task_id and section.section_type == ^section_type,
        order_by: [asc: section.inserted_at],
        limit: 1
    )
  end

  defp single_instance_section_type?(section_type) do
    section_type in @single_instance_section_types
  end

  defp assign_next_section_order(%Changeset{} = changeset) do
    task_id = Changeset.get_field(changeset, :task_id)
    section_type = Changeset.get_field(changeset, :section_type)

    Changeset.put_change(changeset, :section_order, next_section_order(task_id, section_type))
  end

  defp next_section_order(task_id, section_type) do
    max_order =
      Repo.one(
        from section in query(),
          where: section.task_id == ^task_id and section.section_type == ^section_type,
          select: max(section.section_order)
      )

    case max_order do
      nil -> 0
      value -> value + 1
    end
  end

  defp unique_section_order_error?(%Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {:section_order, {_message, opts}} ->
        opts[:constraint] == :unique and
          to_string(opts[:constraint_name]) == "task_sections_unique_order_per_task_and_type"

      _other ->
        false
    end)
  end
end
