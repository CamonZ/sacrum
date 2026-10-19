defmodule Sacrum.Repo.Schemas.WorkflowStep.Config.HumanInput do
  @moduledoc """
  Config for `human_input` steps, which park the run until a human responds.

  `role` tells the resolving agent how to behave and what kind of decision
  the gate is; it is stored verbatim, and null means the client's generic
  role. `question` is a Liquid template framing what must be answered and
  why, rendered with the same context as an `llm_inference` prompt, plus
  `execution.step_visit_count`, when the run parks. `artifact` is the logical
  name of the artifact that resolves the gate, and `output_schema` is the
  JSON Schema the response must satisfy; each top-level property's
  `description` is that field's question. All fields are optional; without
  `output_schema` responses are not validated.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Sacrum.Repo.Schemas.WorkflowStep.Config

  @version 2

  @type t :: %__MODULE__{}

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :version, :integer, default: @version
    field :role, :string
    field :question, :string
    field :artifact, :string
    field :output_schema, :map
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(config, params) do
    config
    |> cast(params, __schema__(:fields))
    |> Config.validate_version(@version)
    |> validate_length(:artifact, max: 255)
    |> Config.validate_output_schema()
  end
end
