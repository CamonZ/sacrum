defmodule Sacrum.Accounts.ChatCatalog do
  @moduledoc "Machine-scoped catalog and permanent deletion tombstones. No task preflight reads."
  alias Sacrum.ChatCatalog.Payload
  alias Sacrum.Repo.ChatCatalog, as: CatalogRepo

  @spec register(String.t(), String.t()) :: {:ok, struct()} | {:error, term()}
  def register(user_id, installation_id), do: CatalogRepo.register(user_id, installation_id)

  @spec list(String.t(), String.t(), String.t(), String.t() | nil, pos_integer(), boolean()) ::
          {:ok, map()} | {:error, term()}
  def list(
        user_id,
        project_id,
        installation_id,
        after_id \\ nil,
        limit \\ 100,
        include_completed \\ false
      ) do
    with :ok <- limit_valid(limit),
         :ok <- include_completed_valid(include_completed) do
      # One extra row distinguishes a full final page from a page with a successor.
      rows =
        CatalogRepo.list(
          user_id,
          project_id,
          installation_id,
          after_id,
          limit + 1,
          include_completed
        )

      page(rows, limit, & &1.chat_id)
    end
  end

  @spec history(String.t(), String.t(), String.t(), String.t() | nil, pos_integer(), boolean()) ::
          {:ok, map()} | {:error, term()}
  def history(user_id, project_id, installation_id, after_cursor, limit, include_completed) do
    with :ok <- limit_valid(limit),
         :ok <- include_completed_valid(include_completed),
         {:ok, cursor} <- decode_history_cursor(after_cursor) do
      rows =
        CatalogRepo.history(
          user_id,
          project_id,
          installation_id,
          cursor,
          limit + 1,
          include_completed
        )

      page(rows, limit, &encode_history_cursor/1)
    end
  end

  defp page(rows, limit, encode_cursor) do
    {entries, lookahead} = Enum.split(rows, limit)
    cursor = if lookahead == [], do: nil, else: encode_cursor.(List.last(entries))
    {:ok, %{entries: entries, next_cursor: cursor}}
  end

  defp encode_history_cursor(entry) do
    [1, DateTime.to_unix(entry.updated_at, :microsecond), entry.chat_id]
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_history_cursor(nil), do: {:ok, nil}

  defp decode_history_cursor(cursor) when is_binary(cursor) and byte_size(cursor) <= 2048 do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, [1, timestamp, chat_id]} when is_integer(timestamp) and is_binary(chat_id) <-
           Jason.decode(json),
         {:ok, updated_at} <- DateTime.from_unix(timestamp, :microsecond),
         # PostgreSQL text parameters reject NUL bytes, so fail here instead of raising.
         true <- chat_id != "" and not String.contains?(chat_id, <<0>>) do
      {:ok, {updated_at, chat_id}}
    else
      _ -> {:error, "invalid chat history cursor"}
    end
  end

  defp decode_history_cursor(_), do: {:error, "invalid chat history cursor"}

  @spec put(String.t(), String.t(), String.t(), String.t(), non_neg_integer(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def put(user_id, project_id, installation_id, chat_id, revision, mutation_id, payload) do
    with :ok <- Payload.validate(payload),
         true <- is_integer(revision) and revision >= 0 do
      CatalogRepo.put(
        user_id,
        project_id,
        installation_id,
        chat_id,
        revision,
        mutation_id,
        payload
      )
    else
      false -> {:error, :invalid_payload}
      error -> error
    end
  end

  defp limit_valid(limit) when is_integer(limit) and limit in 1..200, do: :ok
  defp limit_valid(_), do: {:error, "limit must be between 1 and 200"}
  defp include_completed_valid(value) when is_boolean(value), do: :ok
  defp include_completed_valid(_), do: {:error, "include_completed must be a boolean"}
end
