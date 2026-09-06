defmodule Sacrum.Repo.Schemas.DaemonCredential do
  @moduledoc """
  Persisted daemon credential metadata.

  Only a password hash is stored. Bootstrap credentials are short-lived and
  may be consumed once; reconnect credentials remain valid independently until
  expiry or revocation. Existing credentials migrated from the original schema
  are reconnect credentials, preserving their reusable behavior. The migration
  is intentionally non-lossy on upgrade: it does not silently grant legacy
  rows bootstrap privileges. Its rollback removes classification and
  consumption history and is therefore lossy; use a forward migration before
  production rollback.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @statuses ~w(active revoked)
  @credential_kinds ~w(bootstrap reconnect)
  @json_fields [
    :id,
    :daemon_id,
    :credential_kind,
    :expires_at,
    :consumed_at,
    :revoked_at,
    :status,
    :inserted_at,
    :updated_at
  ]
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @derive {Jason.Encoder, only: @json_fields}

  schema "daemon_credentials" do
    field :token_hash, :string, redact: true
    field :credential_kind, :string, default: "reconnect"
    field :expires_at, :utc_datetime_usec
    field :consumed_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :status, :string, default: "active"
    belongs_to :daemon, Sacrum.Repo.Schemas.Daemon
    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(credential, attrs) do
    credential
    |> cast(attrs, [:token_hash, :expires_at, :status])
    |> force_change(:credential_kind, credential.credential_kind || "reconnect")
    |> validate_required([:daemon_id, :token_hash, :expires_at])
    |> validate_length(:token_hash, min: 20)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:credential_kind, @credential_kinds)
    |> foreign_key_constraint(:daemon_id)
    |> unique_constraint(:token_hash)
    |> check_constraint(:credential_kind, name: :daemon_credentials_credential_kind_check)
    |> check_constraint(:status, name: :daemon_credentials_status_check)
    |> check_constraint(:revoked_at, name: :daemon_credentials_revoked_at_check)
    |> check_constraint(:consumed_at, name: :daemon_credentials_consumed_at_check)
  end

  @spec consume_changeset(t()) :: Ecto.Changeset.t()
  def consume_changeset(credential) do
    credential
    |> change(consumed_at: DateTime.utc_now())
    |> validate_change(:consumed_at, fn :consumed_at, _consumed_at ->
      if consumable?(credential) do
        []
      else
        [consumed_at: "credential is not consumable"]
      end
    end)
  end

  @spec consumable?(t(), DateTime.t()) :: boolean()
  def consumable?(%__MODULE__{} = credential, now \\ DateTime.utc_now()) do
    credential.credential_kind == "bootstrap" and
      credential.status == "active" and is_nil(credential.revoked_at) and
      is_nil(credential.consumed_at) and not is_nil(credential.expires_at) and
      DateTime.compare(credential.expires_at, now) == :gt
  end

  @spec valid_for_authentication?(t(), DateTime.t()) :: boolean()
  def valid_for_authentication?(%__MODULE__{} = credential, now \\ DateTime.utc_now()) do
    credential.status == "active" and
      is_nil(credential.revoked_at) and
      is_nil(credential.consumed_at) and
      not is_nil(credential.expires_at) and DateTime.compare(credential.expires_at, now) == :gt
  end

  @spec revoke_changeset(t()) :: Ecto.Changeset.t()
  def revoke_changeset(credential) do
    change(credential, status: "revoked", revoked_at: DateTime.utc_now())
  end
end
