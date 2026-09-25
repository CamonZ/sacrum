defmodule Sacrum.Repo.Schemas.WorkflowStep.Config.StructuredInference do
  @moduledoc """
  Config for `structured_inference` steps, which send resolved `state` and the
  `fields` JSON Schema to a provider harness and store validated structured
  output.

  `state` is a string, object, or array that may reference task, run, and
  prior-step values with `{{ dotted.path }}` interpolations. `fields` is the
  JSON Schema the harness output must satisfy. Sacrum does not interpret
  `fields` per provider; harnesses map it to their own request shape.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Sacrum.Repo.Schemas.WorkflowStep.Config
  alias Sacrum.Repo.Types.JsonContent
  alias Sacrum.Routing.HandoffTemplate

  @type t :: %__MODULE__{}

  @derive Jason.Encoder
  @primary_key false
  embedded_schema do
    field :version, :integer, default: 1
    field :provider, :string
    field :model, :string
    field :state, JsonContent
    field :fields, :map
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(config, params) do
    config
    |> cast(params, __schema__(:fields))
    |> Config.validate_version()
    |> validate_required([:provider, :model, :state, :fields])
    |> validate_state()
    |> Config.validate_output_schema(:fields)
  end

  defp validate_state(changeset) do
    with state when not is_nil(state) <- get_field(changeset, :state),
         {:error, %{path: path, message: message}} <-
           HandoffTemplate.validate_config_template(%{"state" => state}, "$") do
      add_error(changeset, :state, "#{path}: #{message}")
    else
      _valid -> changeset
    end
  end
end
