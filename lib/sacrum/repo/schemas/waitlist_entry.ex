defmodule Sacrum.Repo.Schemas.WaitlistEntry do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "waitlist_entries" do
    field :email, :string

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @doc """
  Changeset for creating a new waitlist entry.
  """
  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(entry, attrs) do
    entry
    |> cast(attrs, [:email])
    |> validate_required(:email)
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, message: "must be a valid email")
    |> unique_constraint(:email, name: :waitlist_entries_email_index)
  end
end
