defmodule Sacrum.Repo.Migrations.RemoveAuthoringTemplates do
  use Ecto.Migration

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
  @template_kind_values Enum.map_join(@template_kinds, ", ", &"'#{&1}'")

  def up do
    drop_if_exists table(:authoring_templates)
  end

  def down do
    create table(:authoring_templates, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :run_kind, :string, null: false
      add :artifact_type, :string, null: false
      add :template_kind, :string, null: false
      add :state_machine_entrypoint, :string, null: false
      add :name, :string, null: false
      add :payload, :map, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :authoring_templates,
             [
               :run_kind,
               :artifact_type,
               :template_kind,
               :state_machine_entrypoint,
               :name
             ],
             name: :authoring_templates_classification_name_index
           )

    create constraint(:authoring_templates, :authoring_templates_template_kind_check,
             check: "template_kind IN (#{@template_kind_values})"
           )
  end
end
