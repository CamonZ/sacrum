defmodule Sacrum.Accounts.ReviewThreads do
  @moduledoc "Machine-scoped review threads, including permanent tombstones."

  alias Sacrum.Repo.ReviewThreads, as: ThreadsRepo
  alias Sacrum.ReviewThreads.{Payload, Projection}

  @spec list(String.t(), String.t(), String.t(), String.t() | nil, pos_integer()) ::
          {:ok, map()} | {:error, :invalid_payload}
  def list(user_id, project_id, installation_id, after_id, limit) when limit in 1..200 do
    rows = ThreadsRepo.list(user_id, project_id, installation_id, after_id, limit + 1)
    {entries, lookahead} = Enum.split(rows, limit)
    cursor = if lookahead == [], do: nil, else: List.last(entries).id
    {:ok, %{entries: Enum.map(entries, &Projection.entry/1), next_cursor: cursor}}
  end

  def list(_user_id, _project_id, _installation_id, _after_id, _limit),
    do: {:error, :invalid_payload}

  @spec put(String.t(), String.t(), String.t(), String.t(), non_neg_integer(), String.t(), map()) ::
          {:ok, map()} | {:error, :not_found | :invalid_payload}
  def put(user_id, project_id, installation_id, thread_id, revision, mutation_id, payload)
      when is_integer(revision) and revision >= 0 do
    with :ok <- Payload.validate(payload),
         {:ok, result} <-
           ThreadsRepo.with_locked_thread(
             user_id,
             project_id,
             installation_id,
             thread_id,
             mutation_id,
             &apply_write(&1, &2, revision, payload)
           ) do
      {:ok, %{result | entry: project_entry(result.entry)}}
    end
  end

  def put(_user_id, _project_id, _installation_id, _thread_id, _revision, _mutation_id, _payload),
    do: {:error, :invalid_payload}

  defp apply_write(nil, receipt, revision, _payload) when revision != 0 do
    if ThreadsRepo.scope_exists?(receipt),
      do: {:ok, %{status: :conflict, entry: nil}},
      else: {:error, :not_found}
  end

  defp apply_write(nil, receipt, 0, payload), do: persist(nil, receipt, payload)

  defp apply_write(current, receipt, revision, payload) do
    cond do
      ThreadsRepo.receipt_exists?(receipt) ->
        {:ok, %{status: :accepted, entry: current}}

      current.deleted or current.revision != revision ->
        {:ok, %{status: :conflict, entry: current}}

      true ->
        persist(current, receipt, payload)
    end
  end

  defp persist(current, receipt, payload) do
    with {:ok, entry} <- ThreadsRepo.persist(current, receipt, payload) do
      {:ok, %{status: :accepted, entry: entry}}
    end
  end

  defp project_entry(nil), do: nil
  defp project_entry(entry), do: Projection.entry(entry)
end
