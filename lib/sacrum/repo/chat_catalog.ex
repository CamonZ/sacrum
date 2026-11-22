defmodule Sacrum.Repo.ChatCatalog do
  @moduledoc "Catalog database primitives. Ownership is always part of every key."
  import Ecto.Query
  alias Sacrum.Repo
  alias Sacrum.Repo.ReviewThreads
  alias Sacrum.Repo.Schemas.{ChatCatalogEntry, ChatInstallation, Task}

  @spec register(String.t(), String.t()) :: {:ok, ChatInstallation.t()} | {:error, :not_found}
  def register(user_id, id) do
    now = DateTime.utc_now()

    Repo.insert_all(
      ChatInstallation,
      [%{id: id, user_id: user_id, inserted_at: now, updated_at: now}],
      on_conflict: :nothing
    )

    case Repo.get_by(ChatInstallation, id: id, user_id: user_id) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  end

  @spec scope(String.t(), String.t(), String.t()) :: Ecto.Query.t()
  def scope(user_id, project_id, installation_id) do
    from e in ChatCatalogEntry,
      where:
        e.user_id == ^user_id and e.project_id == ^project_id and
          e.installation_id == ^installation_id
  end

  @spec list(String.t(), String.t(), String.t(), String.t() | nil, pos_integer(), boolean()) :: [
          ChatCatalogEntry.t()
        ]
  def list(user_id, project_id, installation_id, after_id, limit, include_completed \\ false) do
    query =
      user_id
      |> scope(project_id, installation_id)
      |> filter_completed_tasks(include_completed)

    query = if after_id, do: where(query, [e], e.chat_id > ^after_id), else: query
    Repo.all(from e in query, order_by: [asc: e.chat_id], limit: ^limit)
  end

  @spec history(
          String.t(),
          String.t(),
          String.t(),
          {DateTime.t(), String.t()} | nil,
          pos_integer(),
          boolean()
        ) :: [ChatCatalogEntry.t()]
  def history(user_id, project_id, installation_id, cursor, limit, include_completed) do
    query =
      user_id
      |> scope(project_id, installation_id)
      |> where([entry], not entry.deleted)
      |> filter_completed_tasks(include_completed)
      |> filter_completed_parent_tasks(include_completed)
      |> before_history_cursor(cursor)

    Repo.all(
      from entry in query, order_by: [desc: entry.updated_at, desc: entry.chat_id], limit: ^limit
    )
  end

  defp before_history_cursor(query, nil), do: query

  defp before_history_cursor(query, {updated_at, chat_id}) do
    # A row comparison lets PostgreSQL seek chat_catalog_entries_history_index to the cursor.
    where(
      query,
      [entry],
      fragment("(?, ?) < (?, ?)", entry.updated_at, entry.chat_id, ^updated_at, ^chat_id)
    )
  end

  defp filter_completed_parent_tasks(query, true), do: query

  defp filter_completed_parent_tasks(query, false) do
    from entry in query,
      left_join: parent in ChatCatalogEntry,
      on:
        not is_nil(entry.review_thread_id) and parent.chat_id == entry.parent_chat_id and
          parent.user_id == entry.user_id and parent.project_id == entry.project_id and
          parent.installation_id == entry.installation_id,
      left_join: task in Task,
      on:
        task.id == parent.task_id and task.project_id == parent.project_id and
          task.user_id == parent.user_id,
      where: is_nil(task.completed_at)
  end

  defp filter_completed_tasks(query, true), do: query

  defp filter_completed_tasks(query, false) do
    from e in query,
      left_join: task in Task,
      on: task.id == e.task_id and task.project_id == e.project_id and task.user_id == e.user_id,
      where: is_nil(task.completed_at)
  end

  @spec put(String.t(), String.t(), String.t(), String.t(), non_neg_integer(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def put(user_id, project_id, installation_id, chat_id, revision, mutation_id, payload) do
    Repo.transaction(fn ->
      # The advisory lock also serializes first inserts, where no row exists yet.
      lock = Enum.join([user_id, installation_id, chat_id], ":")
      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [lock])

      # Match the cascade's thread-before-discussion lock ordering on relinks.
      lock_discussion_thread(user_id, project_id, installation_id, payload)

      # Keep foreign-key checks for concurrent discussion inserts compatible with this lock.
      current =
        Repo.one(
          from e in scope(user_id, project_id, installation_id),
            where: e.chat_id == ^chat_id,
            lock: "FOR NO KEY UPDATE"
        )

      entry = %ChatCatalogEntry{
        user_id: user_id,
        project_id: project_id,
        installation_id: installation_id,
        chat_id: chat_id
      }

      apply_write(current, entry, revision, mutation_id, payload)
    end)
  end

  defp lock_discussion_thread(_user_id, _project_id, _installation_id, %{"deleted" => true}),
    do: :ok

  defp lock_discussion_thread(user_id, project_id, installation_id, %{"review_thread_id" => id})
       when not is_nil(id) do
    Repo.one(
      from thread in ReviewThreads.scope(user_id, project_id, installation_id),
        where: thread.id == ^id,
        select: thread.id,
        lock: "FOR SHARE"
    )
  end

  defp lock_discussion_thread(_user_id, _project_id, _installation_id, _payload), do: :ok

  defp apply_write(%{mutation_id: id} = current, _entry, _revision, id, _payload),
    do: %{status: "accepted", entry: current}

  defp apply_write(%{deleted: true} = current, _entry, _revision, _id, _payload),
    do: %{status: "conflict", entry: current}

  defp apply_write(%{revision: actual} = current, _entry, expected, _id, _payload)
       when actual != expected,
       do: %{status: "conflict", entry: current}

  defp apply_write(nil, _entry, revision, _id, _payload) when revision != 0,
    do: Repo.rollback(:not_found)

  defp apply_write(current, entry, revision, mutation_id, payload) do
    changeset =
      (current || entry)
      |> ChatCatalogEntry.changeset(payload, mutation_id)
      |> Ecto.Changeset.put_change(:revision, revision + 1)

    result = if current, do: Repo.update(changeset), else: Repo.insert(changeset)

    case result do
      {:ok, entry} -> %{status: "accepted", entry: entry}
      {:error, error} -> Repo.rollback(error)
    end
  end
end
