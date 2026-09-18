defmodule Sacrum.Repo.Schemas.TaskWorkspace do
  @moduledoc """
  Task-owned execution placement.

  A workspace is deliberately small.  It identifies the daemon that owns the
  placement and the task's daemon-local worktree path; daemon-local checkout,
  environment, and credential details remain outside the task record.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @fields ~w(daemon_id worktree_path)a
  @derive {Jason.Encoder, only: @fields}
  @primary_key false

  embedded_schema do
    field :daemon_id, :binary_id
    field :worktree_path, :string
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(workspace, attrs) do
    cast(workspace, attrs, @fields, empty_values: [])
  end

  @spec from_attrs(t() | map() | nil) :: t() | nil | :invalid
  def from_attrs(nil), do: nil
  def from_attrs(%__MODULE__{} = workspace), do: workspace

  def from_attrs(attrs) when is_map(attrs) do
    %__MODULE__{
      daemon_id: value(attrs, :daemon_id),
      worktree_path: value(attrs, :worktree_path)
    }
  end

  def from_attrs(_attrs), do: :invalid

  @doc "Normalizes empty workspace input to the absent workspace representation."
  @spec normalize(t() | map() | nil) :: t() | nil | :invalid
  def normalize(attrs) do
    case from_attrs(attrs) do
      :invalid -> :invalid
      %__MODULE__{daemon_id: nil, worktree_path: nil} -> nil
      workspace -> workspace
    end
  end

  defp value(attrs, key) do
    Map.get(attrs, key)
  end
end
