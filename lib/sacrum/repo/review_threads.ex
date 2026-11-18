defmodule Sacrum.Repo.ReviewThreads do
  @moduledoc "Scoped queries and atomic writes for anchored chat discussions."

  import Ecto.Query

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{ChatInstallation, Project, ReviewThread, ReviewThreadMutation}

  @type receipt_key :: %{
          user_id: String.t(),
          project_id: String.t(),
          installation_id: String.t(),
          thread_id: String.t(),
          mutation_id: String.t()
        }

  @spec scope(String.t(), String.t(), String.t()) :: Ecto.Query.t()
  def scope(user_id, project_id, installation_id) do
    from thread in ReviewThread,
      where:
        thread.user_id == ^user_id and thread.project_id == ^project_id and
          thread.installation_id == ^installation_id
  end

  @spec list(String.t(), String.t(), String.t(), String.t() | nil, pos_integer()) ::
          [ReviewThread.t()]
  def list(user_id, project_id, installation_id, after_id, limit) do
    query = scope(user_id, project_id, installation_id)
    query = if after_id, do: where(query, [thread], thread.id > ^after_id), else: query
    Repo.all(from thread in query, order_by: [asc: thread.id], limit: ^limit)
  end

  @doc "Runs a write decision with the scoped thread locked until the transaction ends."
  @spec with_locked_thread(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          (ReviewThread.t() | nil, receipt_key() -> {:ok, result} | {:error, reason})
        ) :: {:ok, result} | {:error, reason}
        when result: var, reason: var
  def with_locked_thread(user_id, project_id, installation_id, thread_id, mutation_id, decide) do
    receipt = %{
      user_id: Ecto.UUID.cast!(user_id),
      project_id: Ecto.UUID.cast!(project_id),
      installation_id: Ecto.UUID.cast!(installation_id),
      thread_id: Ecto.UUID.cast!(thread_id),
      mutation_id: Ecto.UUID.cast!(mutation_id)
    }

    Repo.transact(fn ->
      # The unique key spans projects within an installation, including first inserts.
      lock_key =
        Enum.join(
          ["review_threads", receipt.user_id, receipt.installation_id, receipt.thread_id],
          ":"
        )

      Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [lock_key])

      current =
        Repo.one(
          from row in scope(receipt.user_id, receipt.project_id, receipt.installation_id),
            where: row.id == ^receipt.thread_id,
            lock: "FOR UPDATE"
        )

      decide.(current, receipt)
    end)
  end

  @spec scope_exists?(receipt_key()) :: boolean()
  def scope_exists?(%{user_id: user_id, project_id: project_id, installation_id: installation_id}) do
    Repo.exists?(where(Project, id: ^project_id, user_id: ^user_id)) and
      Repo.exists?(where(ChatInstallation, id: ^installation_id, user_id: ^user_id))
  end

  @spec receipt_exists?(receipt_key()) :: boolean()
  def receipt_exists?(receipt),
    do: Repo.exists?(where(ReviewThreadMutation, ^Map.to_list(receipt)))

  @doc "Persists a thread and its receipt inside the caller's locked transaction."
  @spec persist(ReviewThread.t() | nil, receipt_key(), map()) ::
          {:ok, ReviewThread.t()} | {:error, :not_found | :invalid_payload}
  def persist(current, receipt, payload) do
    thread =
      current ||
        %ReviewThread{
          id: receipt.thread_id,
          user_id: receipt.user_id,
          project_id: receipt.project_id,
          installation_id: receipt.installation_id
        }

    changeset = ReviewThread.changeset(thread, payload)

    # Every new accepted mutation advances the revision, even with identical payload.
    result =
      if current,
        do: Repo.update(changeset, force: true, returning: [:updated_at]),
        else: Repo.insert(changeset)

    case result do
      {:ok, entry} ->
        {1, _} = Repo.insert_all(ReviewThreadMutation, [receipt])
        {:ok, entry}

      {:error, changeset} ->
        {:error, Repo.WriteError.from_changeset(changeset)}
    end
  end
end
