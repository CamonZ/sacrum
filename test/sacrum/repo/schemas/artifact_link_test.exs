defmodule Sacrum.Repo.Schemas.ArtifactLinkTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Schemas.ArtifactLink

  defp artifact_link do
    struct(ArtifactLink, %{
      artifact_id: Ecto.UUID.generate(),
      subject_id: Ecto.UUID.generate(),
      project_id: Ecto.UUID.generate(),
      user_id: Ecto.UUID.generate()
    })
  end

  defp valid_attrs(attrs) do
    Map.merge(
      %{
        subject_type: "task",
        relationship_kind: "attached_to",
        metadata: %{"label" => "implementation evidence"}
      },
      attrs
    )
  end

  describe "create_changeset/2" do
    test "requires artifact, subject, relationship, and ownership fields" do
      changeset = ArtifactLink.create_changeset(struct(ArtifactLink), %{})

      assert %{
               artifact_id: ["can't be blank"],
               subject_type: ["can't be blank"],
               subject_id: ["can't be blank"],
               relationship_kind: ["can't be blank"],
               project_id: ["can't be blank"],
               user_id: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "accepts supported subject and relationship values" do
      for subject_type <- [
            "task",
            "task_section",
            "workflow",
            "task_run",
            "step_execution"
          ],
          relationship_kind <- ["evidence_for", "attached_to"] do
        changeset =
          artifact_link()
          |> ArtifactLink.create_changeset(
            valid_attrs(%{
              subject_type: subject_type,
              relationship_kind: relationship_kind
            })
          )

        assert changeset.valid?,
               "expected #{inspect({subject_type, relationship_kind})} to be valid"
      end
    end

    test "rejects values outside the artifact link persistence contract" do
      changeset =
        artifact_link()
        |> ArtifactLink.create_changeset(
          valid_attrs(%{
            subject_type: "workflow_step",
            relationship_kind: "mentions"
          })
        )

      assert %{
               subject_type: ["is invalid"],
               relationship_kind: ["is invalid"]
             } = errors_on(changeset)
    end
  end
end
