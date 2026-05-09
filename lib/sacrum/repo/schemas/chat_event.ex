defmodule Sacrum.Repo.Schemas.ChatEvent do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @visibilities [:public, :internal]
  @create_fields ~w(event_type visibility public_payload internal_payload)a
  @required_fields ~w(chat_session_id project_id user_id event_type visibility public_payload internal_payload)a

  schema "chat_events" do
    field :event_type, :string
    field :visibility, Ecto.Enum, values: @visibilities, default: :public
    field :public_payload, :map, default: %{}
    field :internal_payload, :map, default: %{}

    belongs_to :chat_session, Sacrum.Repo.Schemas.ChatSession
    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :user, Sacrum.Repo.Schemas.User

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec visibilities() :: [atom()]
  def visibilities, do: @visibilities

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(chat_event, attrs) do
    chat_event
    |> cast(attrs, @create_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:chat_session_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:user_id)
    |> check_constraint(:visibility, name: :chat_events_visibility_check)
  end
end
