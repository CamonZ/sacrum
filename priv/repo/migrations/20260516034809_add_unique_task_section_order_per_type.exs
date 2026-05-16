defmodule Sacrum.Repo.Migrations.AddUniqueTaskSectionOrderPerType do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE task_sections AS section
    SET section_order = NULL
    FROM (
      SELECT id
      FROM (
        SELECT
          id,
          row_number() OVER (
            PARTITION BY task_id, section_type, section_order
            ORDER BY inserted_at ASC, id ASC
          ) AS duplicate_position
        FROM task_sections
        WHERE section_order IS NOT NULL
      ) AS ranked_sections
      WHERE duplicate_position > 1
    ) AS duplicates
    WHERE section.id = duplicates.id
    """)

    create unique_index(:task_sections, [:task_id, :section_type, :section_order],
             name: :task_sections_unique_order_per_task_and_type,
             where: "section_order IS NOT NULL"
           )
  end

  def down do
    drop_if_exists index(:task_sections, [:task_id, :section_type, :section_order],
                     name: :task_sections_unique_order_per_task_and_type
                   )
  end
end
