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

  @scalar_types ~w(string number integer boolean)

  @doc """
  Whether responses can be built field by field as a draft.

  True when `output_schema` is an object whose top-level properties are each
  a string, number, integer or boolean, a string enum, or an array of string
  enum (the MCP elicitation subset). A gate without `output_schema` is not
  draftable.
  """
  @spec draftable?(t() | map() | nil) :: boolean()
  def draftable?(%__MODULE__{output_schema: schema}), do: draftable?(schema)

  def draftable?(%{"type" => "object", "properties" => properties})
      when is_map(properties) and map_size(properties) > 0,
      do: Enum.all?(properties, fn {_name, property} -> draftable_property?(property) end)

  def draftable?(_schema), do: false

  defp draftable_property?(%{"type" => type} = property) when type in @scalar_types,
    do: not Map.has_key?(property, "enum") or (type == "string" and string_enum?(property))

  defp draftable_property?(%{"type" => "array", "items" => %{"type" => "string"} = items}),
    do: string_enum?(items)

  defp draftable_property?(_property), do: false

  defp string_enum?(%{"enum" => [_ | _] = values}), do: Enum.all?(values, &is_binary/1)
  defp string_enum?(_schema), do: false

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(config, params) do
    config
    |> cast(params, __schema__(:fields))
    |> Config.validate_version(@version)
    |> validate_length(:artifact, max: 255)
    |> Config.validate_output_schema()
  end
end
