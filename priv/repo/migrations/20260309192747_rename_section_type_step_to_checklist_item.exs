defmodule Sacrum.Repo.Migrations.RenameSectionTypeStepToChecklistItem do
  use Ecto.Migration

  def change do
    # Rename all existing 'step' section_type values to 'checklist_item'
    execute(
      "UPDATE task_sections SET section_type = 'checklist_item' WHERE section_type = 'step'",
      "UPDATE task_sections SET section_type = 'step' WHERE section_type = 'checklist_item'"
    )
  end
end
