defmodule Sacrum.Repo.Schemas.WorkflowStep.Config.WaitChildren do
  @moduledoc """
  Config for `wait_children` steps. `output_schema` validates the child-state
  snapshot when the step persists it as an artifact.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Sacrum.Repo.Schemas.WorkflowStep.Config

  @type t :: %__MODULE__{}

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :version, :integer, default: 1
    field :output_schema, :map
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(config, params) do
    config
    |> cast(params, __schema__(:fields))
    |> Config.validate_version()
    |> Config.validate_output_schema()
  end
end
