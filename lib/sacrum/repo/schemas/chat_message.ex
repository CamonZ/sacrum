defmodule Sacrum.Repo.Schemas.ChatMessage do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles [:user, :assistant, :status]
  @content_formats [:plain, :markdown]
  @default_content_format :plain
  @create_fields ~w(role content content_format client_message_id metadata)a
  @required_fields ~w(chat_session_id project_id user_id role content content_format)a

  schema "chat_messages" do
    field :role, Ecto.Enum, values: @roles
    field :content, :string
    field :content_format, Ecto.Enum, values: @content_formats, default: @default_content_format
    field :client_message_id, :string
    field :metadata, :map, default: %{}

    belongs_to :chat_session, Sacrum.Repo.Schemas.ChatSession
    belongs_to :project, Sacrum.Repo.Schemas.Project
    belongs_to :user, Sacrum.Repo.Schemas.User

    timestamps(type: :utc_datetime_usec)
  end

  @spec roles() :: [atom()]
  def roles, do: @roles

  @spec content_formats() :: [atom()]
  def content_formats, do: @content_formats

  @spec default_content_format() :: atom()
  def default_content_format, do: @default_content_format

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(chat_message, attrs) do
    chat_message
    |> cast(attrs, @create_fields)
    |> validate_required(@required_fields)
    |> foreign_key_constraint(:chat_session_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:chat_session_id, :client_message_id])
    |> check_constraint(:role, name: :chat_messages_role_check)
    |> check_constraint(:content_format, name: :chat_messages_content_format_check)
  end
end
