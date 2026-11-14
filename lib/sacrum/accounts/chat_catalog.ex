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

      {entries, lookahead} = Enum.split(rows, limit)
      # Resume after the last returned row, so the lookahead row is not skipped.
      cursor = if lookahead == [], do: nil, else: List.last(entries).chat_id
      {:ok, %{entries: entries, next_cursor: cursor}}
    end
  end

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
      false -> {:error, "invalid revision"}
      error -> error
    end
  end

  defp limit_valid(limit) when is_integer(limit) and limit in 1..200, do: :ok
  defp limit_valid(_), do: {:error, "limit must be between 1 and 200"}
  defp include_completed_valid(value) when is_boolean(value), do: :ok
  defp include_completed_valid(_), do: {:error, "include_completed must be a boolean"}
end
