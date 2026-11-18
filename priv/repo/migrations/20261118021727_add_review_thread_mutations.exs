defmodule Sacrum.Repo.Migrations.AddReviewThreadMutations do
  use Ecto.Migration

  def up do
    create table(:review_thread_mutations, primary_key: false) do
      add :user_id, :uuid, primary_key: true
      add :project_id, :uuid, primary_key: true
      add :installation_id, :uuid, primary_key: true
      add :thread_id, :uuid, primary_key: true
      add :mutation_id, :uuid, primary_key: true
    end

    execute """
    ALTER TABLE review_thread_mutations
      ADD CONSTRAINT review_thread_mutations_thread_fkey
      FOREIGN KEY (thread_id, user_id, project_id, installation_id)
      REFERENCES review_threads (id, user_id, project_id, installation_id)
      ON DELETE CASCADE
    """

    execute """
    INSERT INTO review_thread_mutations (thread_id, user_id, project_id, installation_id, mutation_id)
    SELECT id, user_id, project_id, installation_id, mutation_id FROM review_threads
    """
  end

  def down do
    drop table(:review_thread_mutations)
  end
end
