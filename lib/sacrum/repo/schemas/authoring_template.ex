defmodule Sacrum.Repo.Schemas.AuthoringTemplate do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}
  @primary_key {:id, :binary_id, autogenerate: true}

  @template_kinds ~w(
    entrypoint
    authoring_rules
    section_template
    workflow_recipe
    step_template
    prompt_template
    route_schema
    validation_policy
    starter_draft
  )

  @classification_fields ~w(run_kind artifact_type template_kind state_machine_entrypoint)a
  @fields @classification_fields ++ ~w(name payload)a
  @required_fields @fields

  schema "authoring_templates" do
    field :run_kind, :string
    field :artifact_type, :string
    field :template_kind, :string
    field :state_machine_entrypoint, :string
    field :name, :string
    field :payload, :map

    timestamps(type: :utc_datetime_usec)
  end

  @spec template_kinds() :: [String.t()]
  def template_kinds, do: @template_kinds

  @spec classification_fields() :: [atom()]
  def classification_fields, do: @classification_fields

  @spec create_changeset(t(), map()) :: Ecto.Changeset.t()
  def create_changeset(template, attrs) do
    template
    |> cast(attrs, @fields)
    |> validate_required(@required_fields)
    |> validate_length(:run_kind, min: 1, max: 255)
    |> validate_length(:artifact_type, min: 1, max: 255)
    |> validate_length(:state_machine_entrypoint, min: 1, max: 255)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:template_kind, @template_kinds)
    |> validate_change(:payload, &validate_payload/2)
    |> unique_constraint(
      [:run_kind, :artifact_type, :template_kind, :state_machine_entrypoint, :name],
      name: :authoring_templates_classification_name_index
    )
    |> check_constraint(:template_kind, name: :authoring_templates_template_kind_check)
  end

  defp validate_payload(:payload, payload) when is_map(payload) and map_size(payload) > 0, do: []

  defp validate_payload(:payload, payload) when is_map(payload),
    do: [payload: "must be a non-empty map"]
end
