defmodule Sacrum.Repo.Migrations.PreserveTaskRunHistoryOnLineageDeletion do
  use Ecto.Migration

  # Lineage describes provenance, not ownership. Only task_id owns run history;
  # deleting an ancestor must not erase runs owned by surviving tasks.
  def up do
    replace_lineage_constraints("SET NULL", "SET NULL")
  end

  def down do
    replace_lineage_constraints("CASCADE", "NO ACTION")
  end

  defp replace_lineage_constraints(parent_action, root_action) do
    execute """
    ALTER TABLE task_runs
      DROP CONSTRAINT task_runs_parent_task_run_id_fkey,
      DROP CONSTRAINT task_runs_root_task_run_id_fkey,
      ADD CONSTRAINT task_runs_parent_task_run_id_fkey
        FOREIGN KEY (parent_task_run_id) REFERENCES task_runs(id)
        ON DELETE #{parent_action},
      ADD CONSTRAINT task_runs_root_task_run_id_fkey
        FOREIGN KEY (root_task_run_id) REFERENCES task_runs(id)
        ON DELETE #{root_action}
    """
  end
end
