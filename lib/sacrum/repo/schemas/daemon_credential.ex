defmodule Sacrum.Repo.Schemas.DaemonCredential do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @statuses ~w(active revoked)
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "daemon_credentials" do
    field :token_hash, :string, redact: true
    field :expires_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :status, :string, default: "active"
    belongs_to :daemon, Sacrum.Repo.Schemas.Daemon
    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(credential, attrs) do
    credential
    |> cast(attrs, [:token_hash, :expires_at, :status])
    |> validate_required([:daemon_id, :token_hash, :expires_at])
    |> validate_length(:token_hash, min: 20)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:daemon_id)
    |> unique_constraint(:token_hash)
  end

  @spec revoke_changeset(t()) :: Ecto.Changeset.t()
  def revoke_changeset(credential) do
    change(credential, status: "revoked", revoked_at: DateTime.utc_now())
  end
end
