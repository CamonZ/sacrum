defmodule Sacrum.Repo.Schemas.WorkflowStep.Config.LlmInference do
  @moduledoc "Config for `llm_inference` steps, which run a prompt on a daemon."

  use Ecto.Schema

  import Ecto.Changeset

  alias Sacrum.Repo.Schemas.WorkflowStep.Config

  @type t :: %__MODULE__{}

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :version, :integer, default: 1
    field :prompt, :string
    field :output_schema, :map
    field :agents, {:array, :string}, default: []
    field :skills, {:array, :string}, default: []
    field :agent_config, :map, default: %{}
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(config, params) do
    # Keep an empty prompt distinct from a missing one.
    config
    |> cast(params, __schema__(:fields), empty_values: [])
    |> Config.validate_version()
    |> Config.validate_output_schema()
  end
end
