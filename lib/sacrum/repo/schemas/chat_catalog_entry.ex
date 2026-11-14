defmodule Sacrum.Repo.Schemas.ChatCatalogEntry do
  use Ecto.Schema
  import Ecto.Changeset
  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "chat_catalog_entries" do
    belongs_to :user, Sacrum.Repo.Schemas.User
    belongs_to :project, Sacrum.Repo.Schemas.Project
    field :installation_id, :binary_id
    field :chat_id, :string
    field :status, Ecto.Enum, values: [:idle, :working], default: :idle
    belongs_to :task, Sacrum.Repo.Schemas.Task
    field :parent_chat_id, :string
    field :gate_execution_id, :binary_id
    field :gate_task_run_id, :binary_id
    field :metadata, :map, default: %{}
    field :classifications, {:array, :map}, default: []
    field :deleted, :boolean, default: false
    field :revision, :integer, default: 1
    field :mutation_id, :binary_id
    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map(), String.t()) :: Ecto.Changeset.t()
  def changeset(entry, payload, mutation_id) do
    entry
    |> cast(payload, [
      :status,
      :task_id,
      :parent_chat_id,
      :gate_execution_id,
      :gate_task_run_id,
      :metadata,
      :classifications,
      :deleted
    ])
    |> put_change(:mutation_id, mutation_id)
    |> validate_required([:user_id, :project_id, :installation_id, :chat_id, :mutation_id])
    |> validate_length(:chat_id, min: 1, max: 200)
    |> check_constraint(:status, name: :chat_catalog_status_valid)
    |> foreign_key_constraint(:project_id, name: :chat_catalog_project_scope_fkey)
    |> foreign_key_constraint(:installation_id, name: :chat_catalog_installation_scope_fkey)
    |> foreign_key_constraint(:task_id, name: :chat_catalog_task_scope_fkey)
    |> foreign_key_constraint(:parent_chat_id, name: :chat_catalog_parent_scope_fkey)
    |> foreign_key_constraint(:gate_execution_id, name: :chat_catalog_execution_scope_fkey)
    |> foreign_key_constraint(:gate_task_run_id, name: :chat_catalog_run_scope_fkey)
    |> unique_constraint([:user_id, :installation_id, :chat_id])
  end

  @spec payload(t()) :: map()
  def payload(entry) do
    fields =
      Map.new(
        ~w(metadata classifications task_id parent_chat_id gate_execution_id gate_task_run_id deleted)a,
        fn key -> {Atom.to_string(key), Map.get(entry, key)} end
      )

    Map.put(fields, "status", to_string(entry.status))
  end
end
