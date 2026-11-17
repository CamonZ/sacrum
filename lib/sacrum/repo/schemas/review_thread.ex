defmodule Sacrum.Repo.Schemas.ReviewThread do
  @moduledoc "Git coordinates for an anchored chat discussion."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key false
  @scope_fields [:user_id, :project_id, :installation_id]
  @anchor_fields ~w(path side home_kind tool_use_id original_commit_id original_blob_id original_start_line original_line)a
  @immutable_fields [:id, :parent_chat_id | @anchor_fields]
  @mutable_fields ~w(start_line line status outdated_noted origin_kind origin_ref deleted mutation_id)a
  @object_id ~r/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/

  schema "review_threads" do
    field :id, :binary_id, primary_key: true
    field :user_id, :binary_id, primary_key: true
    field :project_id, :binary_id, primary_key: true
    field :installation_id, :binary_id, primary_key: true
    field :parent_chat_id, :string
    field :path, :string
    field :side, Ecto.Enum, values: [left: "LEFT", right: "RIGHT"]
    field :home_kind, Ecto.Enum, values: [:worktree, :tool_call]
    field :tool_use_id, :string
    field :original_commit_id, :string
    field :original_blob_id, :string
    field :original_start_line, :integer
    field :original_line, :integer
    field :start_line, :integer
    field :line, :integer
    field :status, Ecto.Enum, values: [:open, :outdated], default: :open
    field :outdated_noted, :boolean, default: false
    field :origin_kind, Ecto.Enum, values: [:local], default: :local
    field :origin_ref, :string
    field :deleted, :boolean, default: false
    field :revision, :integer, default: 1, read_after_writes: true
    field :mutation_id, :binary_id
    timestamps(type: :utc_datetime_usec)
  end

  @doc "Builds a changeset from a struct initialized with trusted scope IDs."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = thread, attrs) do
    thread
    |> cast(attrs, @immutable_fields ++ @mutable_fields, empty_values: [])
    |> validate_immutable()
    |> validate_required(
      @scope_fields ++
        ~w(id parent_chat_id path side home_kind original_commit_id original_blob_id original_start_line original_line status outdated_noted origin_kind deleted mutation_id)a
    )
    |> validate_length(:parent_chat_id, max: 200, count: :codepoints)
    |> validate_length(:path, max: 4096, count: :codepoints)
    |> validate_format(:path, ~r/\A(?!\/)(?!.*(?:\A|\/)\.\.(?:\/|\z))[^\x00]+\z/s,
      message: "must be a repository-relative path"
    )
    |> validate_format(:original_commit_id, @object_id)
    |> validate_format(:original_blob_id, @object_id)
    |> validate_home()
    |> validate_range(:original_start_line, :original_line)
    |> validate_position()
    |> foreign_key_constraint(:project_id, name: :review_threads_project_scope_fkey)
    |> foreign_key_constraint(:installation_id, name: :review_threads_installation_scope_fkey)
    |> foreign_key_constraint(:parent_chat_id, name: :review_threads_parent_scope_fkey)
    |> unique_constraint([:user_id, :installation_id, :id])
    |> check_constraint(:path, name: :review_threads_anchor_immutable)
    |> check_constraint(:deleted, name: :review_threads_tombstone_terminal)
  end

  defp validate_immutable(%{data: %{__meta__: %{state: :built}}} = changeset), do: changeset

  defp validate_immutable(changeset) do
    changeset =
      Enum.reduce(@immutable_fields, changeset, fn field, changeset ->
        if changed?(changeset, field),
          do: add_error(changeset, field, "cannot change after insertion"),
          else: changeset
      end)

    if changeset.data.deleted,
      do: add_error(changeset, :deleted, "thread is tombstoned"),
      else: changeset
  end

  defp validate_home(changeset) do
    if get_field(changeset, :home_kind) == :tool_call do
      validate_required(changeset, :tool_use_id)
    else
      changeset
    end
  end

  defp validate_position(changeset) do
    case get_field(changeset, :status) do
      :open ->
        changeset
        |> validate_required([:start_line, :line])
        |> validate_range(:start_line, :line)

      :outdated ->
        if is_nil(get_field(changeset, :start_line)) and is_nil(get_field(changeset, :line)),
          do: changeset,
          else: add_error(changeset, :line, "current coordinates must be empty when outdated")

      _ ->
        changeset
    end
  end

  defp validate_range(changeset, start_field, end_field) do
    changeset =
      changeset
      |> validate_number(start_field, greater_than: 0)
      |> validate_number(end_field, greater_than: 0)

    first = get_field(changeset, start_field)
    last = get_field(changeset, end_field)

    if is_integer(first) and is_integer(last) and first > last,
      do: add_error(changeset, end_field, "must be at or after the start line"),
      else: changeset
  end
end
