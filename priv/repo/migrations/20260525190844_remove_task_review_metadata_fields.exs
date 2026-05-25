defmodule Sacrum.Repo.Migrations.RemoveTaskReviewMetadataFields do
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      remove :needs_human_review, :boolean, default: false
      remove :review_comment, :text
      remove :revision_feedback, :text
    end
  end
end
