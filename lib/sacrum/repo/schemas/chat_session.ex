defmodule Sacrum.Repo.Schemas.ChatSession do
  use Ecto.Schema
  import Ecto.Changeset

  alias Sacrum.ChatSessions.Status, as: ChatSessionStatus

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ChatSessionStatus.values()

  @create_fields ~w(
    status session_kind started_at ended_at stop_requested_at engine_kind
    engine_session_ref definition_ref public_metadata
  )a
  @required_fields ~w(project_id user_id status session_kind)a

  @update_fields @create_fields

  schema "chat_sessions" do
    field :status, Ecto.Enum, values: @statuses, default: :queued
    field :session_kind, :string, default: "planning"
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
    field :stop_requested_at, :utc_datetime_usec
    field :engine_kind, :string
    field :engine_session_ref, :string
    field :definition_ref, :string
    field :public_metadata, :map, default: %{}

    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :user, Sacrum.Repo.Schemas.User

    has_many :chat_messages, Sacrum.Repo.Schemas.ChatMessage
    has_many :chat_events, Sacrum.Repo.Schemas.ChatEvent

    timestamps(type: :utc_datetime_usec)
  end

  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(chat_session, attrs) do
    chat_session
    |> cast(attrs, @create_fields)
    |> validate_required(@required_fields)
    |> put_lifecycle_timestamps()
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:user_id)
    |> check_constraint(:status, name: :chat_sessions_status_check)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(chat_session, attrs) do
    chat_session
    |> cast(attrs, @update_fields)
    |> validate_required(@required_fields)
    |> put_lifecycle_timestamps()
    |> check_constraint(:status, name: :chat_sessions_status_check)
  end

  defp put_lifecycle_timestamps(changeset) do
    status = get_field(changeset, :status)

    changeset
    |> maybe_put_started_at(status)
    |> maybe_put_stop_requested_at(status)
    |> maybe_put_ended_at(status)
  end

  defp maybe_put_started_at(changeset, status) when status in [:running, :waiting] do
    put_missing_timestamp(changeset, :started_at)
  end

  defp maybe_put_started_at(changeset, _status), do: changeset

  defp maybe_put_stop_requested_at(changeset, :cancelling) do
    put_missing_timestamp(changeset, :stop_requested_at)
  end

  defp maybe_put_stop_requested_at(changeset, _status), do: changeset

  defp maybe_put_ended_at(changeset, status) do
    if ChatSessionStatus.terminal?(status) do
      put_missing_timestamp(changeset, :ended_at)
    else
      changeset
    end
  end

  defp put_missing_timestamp(changeset, field) do
    case get_field(changeset, field) do
      nil -> put_change(changeset, field, DateTime.utc_now())
      _timestamp -> changeset
    end
  end
end
