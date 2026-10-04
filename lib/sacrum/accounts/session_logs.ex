defmodule Sacrum.Accounts.SessionLogs do
  @moduledoc """
  User-scoped session log operations.

  All operations are scoped to a specific user.
  """

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.SessionLogs,
    preloads: [],
    default_order: [asc: :inserted_at]

  alias Sacrum.Accounts.SessionLogs.Ingestion
  alias Sacrum.Accounts.StepExecutions
  alias Sacrum.Repo.Schemas.SessionLog

  @doc """
  Ingest a harness event for a user's step execution.
  Takes step_execution_id from attrs and derives project_id from the execution.

  Streaming text deltas are published without a row; see
  `Sacrum.Accounts.SessionLogs.Ingestion`.
  """
  @spec insert(String.t(), map()) ::
          {:ok, SessionLog.t()}
          | {:error,
             Ecto.Changeset.t()
             | :event_identity_conflict
             | :not_found
             | :invalid_attributes
             | :ingestion_failed}
  def insert(user_id, attrs) when is_binary(user_id) and is_map(attrs) do
    normalized = Enum.map(attrs, fn {key, value} -> {to_string(key), value} end)
    keys = Enum.map(normalized, &elem(&1, 0))

    if length(Enum.uniq(keys)) == length(keys) do
      insert_normalized(user_id, Map.new(normalized))
    else
      {:error, :invalid_attributes}
    end
  end

  defp insert_normalized(user_id, attrs) do
    case Ecto.UUID.cast(Map.get(attrs, "step_execution_id")) do
      {:ok, execution_id} ->
        case StepExecutions.get_by(user_id, conditions: [id: execution_id]) do
          {:ok, execution} ->
            Ingestion.ingest(execution, Map.put(attrs, "project_id", execution.project_id))

          {:error, reason} ->
            {:error, reason}
        end

      :error ->
        {:error, :not_found}
    end
  end
end
