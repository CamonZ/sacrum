defmodule Sacrum.Repo.Schemas.Daemon do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @statuses ~w(pending active revoked)
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "daemons" do
    field :status, :string, default: "pending"
    belongs_to :user, Sacrum.Repo.Schemas.User
    has_many :credentials, Sacrum.Repo.Schemas.DaemonCredential
    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(daemon, attrs) do
    daemon
    |> cast(attrs, [:status])
    |> validate_required([:user_id])
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:user_id)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(daemon, attrs) do
    daemon |> cast(attrs, [:status]) |> validate_inclusion(:status, @statuses)
  end
end
