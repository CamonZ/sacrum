defmodule Sacrum.Repo.Schemas.Daemon do
  @moduledoc """
  Daemon fleet identity and credential-enrollment state.

  `status` is credential-enrollment lifecycle, not connection health:

    * `pending` — provisioned with an unconsumed bootstrap credential.
    * `active` — completed at least one bootstrap exchange under this schema.
    * `revoked` — terminal; all credentials invalid.

  It never claims the daemon is online. Terminal identities fail every
  credential operation through `credential_eligible?/1`, an explicit
  allowlist rather than a `!= "revoked"` comparison, so future terminal
  states (for example a removal tombstone) cannot accidentally requalify.
  `enrolled_at` records the first successful exchange observed by this
  schema version and survives rotation; rows provisioned before the field
  existed keep it NULL (unknown).

  Display names are optional. The validation policy is shared by create and
  rename: the value is trimmed, must contain 1..100 characters after trimming,
  and is unique per owner case-insensitively through the
  `daemons_user_id_lower_name_index` expression index. Unnamed rows render
  with a stable short-ID fallback; they are never backfilled.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @statuses ~w(pending active revoked)
  @credential_eligible_statuses ~w(pending active)
  @name_unique_index :daemons_user_id_lower_name_index
  @name_max_length 100
  @fallback_id_length 8
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "daemons" do
    field :name, :string
    field :status, :string, default: "pending"
    field :enrolled_at, :utc_datetime_usec
    belongs_to :user, Sacrum.Repo.Schemas.User
    has_many :credentials, Sacrum.Repo.Schemas.DaemonCredential
    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Client-editable fields only. Lifecycle status and ownership are trusted
  inputs set by internal lifecycle changesets; `user_id` is set explicitly on
  the struct and never cast. `empty_values: []` keeps blank names as explicit
  input so the shared policy rejects them instead of silently clearing.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(daemon, attrs) do
    daemon
    |> cast(attrs, [:name], empty_values: [])
    |> validate_name()
    |> validate_required([:user_id])
    |> foreign_key_constraint(:user_id)
  end

  @doc "Renames (or clears, with `nil`) the display name using the shared policy."
  @spec name_changeset(t(), map()) :: Ecto.Changeset.t()
  def name_changeset(daemon, attrs) do
    daemon |> cast(attrs, [:name], empty_values: []) |> validate_name()
  end

  @doc "Trusted lifecycle status transition; never exposed to client attrs."
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(daemon, attrs) do
    daemon |> cast(attrs, [:status]) |> validate_inclusion(:status, @statuses)
  end

  @doc """
  Records first credential enrollment atomically with the consuming exchange.
  Trusted internal path: a `pending` daemon becomes `active`, and
  `enrolled_at` is written only when still unknown so rotation preserves the
  first observed enrollment time.
  """
  @spec enroll_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def enroll_changeset(%__MODULE__{} = daemon, %DateTime{} = enrolled_at) do
    daemon
    |> change(enrolled_at: enrolled_at)
    |> activate_if_pending()
    |> validate_inclusion(:status, @statuses)
  end

  @doc "Stable display fallback for unnamed legacy or new rows: the short ID."
  @spec display_name(t()) :: String.t()
  def display_name(%__MODULE__{name: name}) when is_binary(name) and name != "",
    do: name

  def display_name(%__MODULE__{id: id}) when is_binary(id),
    do: binary_part(id, 0, @fallback_id_length)

  @doc """
  Terminal-state guard for credential operations (exchange, rotation,
  reconnect). Uses an explicit allowlist, so any later terminal tombstone
  state cannot pass a naive `status != "revoked"` check.
  """
  @spec credential_eligible?(t()) :: boolean()
  @spec credential_eligible?(String.t()) :: boolean()
  def credential_eligible?(%__MODULE__{status: status}), do: credential_eligible?(status)

  def credential_eligible?(status) when is_binary(status),
    do: status in @credential_eligible_statuses

  defp validate_name(changeset) do
    changeset
    |> update_change(:name, &trim_name/1)
    |> validate_length(:name, min: 1, max: @name_max_length)
    |> unique_constraint(:name, name: @name_unique_index)
  end

  defp trim_name(nil), do: nil
  defp trim_name(name) when is_binary(name), do: String.trim(name)

  defp activate_if_pending(%Ecto.Changeset{data: %__MODULE__{status: "pending"}} = changeset),
    do: change(changeset, status: "active")

  defp activate_if_pending(changeset), do: changeset
end
