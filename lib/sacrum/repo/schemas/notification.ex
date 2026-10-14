defmodule Sacrum.Repo.Schemas.Notification do
  @moduledoc """
  A durable, daemon-composed notification owned by a project and its user.

  `message` is Markdown stored exactly as received. Inline link destinations
  (for example `vtb://task/<uuid>`) are data: they are not parsed, resolved, or
  snapshotted at publication. The message never changes after publication;
  `read_at` is the only mutable field.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @severities ~w(info success warning error)
  @max_message_bytes 4_096
  @project_scope_constraint "notifications_project_scope_fkey"

  schema "notifications" do
    field :message, :string
    field :severity, :string
    field :read_at, :utc_datetime_usec

    belongs_to :user, Sacrum.Repo.Schemas.User
    belongs_to :project, Sacrum.Repo.Schemas.Project

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @spec severities() :: [String.t()]
  def severities, do: @severities

  @spec max_message_bytes() :: pos_integer()
  def max_message_bytes, do: @max_message_bytes

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(notification, attrs) do
    notification
    |> cast(attrs, [:message, :severity])
    |> validate_required([:user_id, :project_id, :message, :severity])
    |> validate_length(:message, max: @max_message_bytes, count: :bytes)
    |> validate_inclusion(:severity, @severities)
    |> check_constraint(:severity, name: :notifications_severity_check)
    |> foreign_key_constraint(:project_id, name: @project_scope_constraint)
    |> foreign_key_constraint(:user_id)
  end
end
