defmodule Sacrum.Repo.Schemas.ChatInstallation do
  use Ecto.Schema
  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id
  schema "chat_installations" do
    belongs_to :user, Sacrum.Repo.Schemas.User, primary_key: true
    timestamps(type: :utc_datetime_usec)
  end
end
