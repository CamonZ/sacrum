defmodule Sacrum.Repo.Schemas.ArtifactTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.Schemas.Artifact

  defp artifact do
    struct(Artifact, %{
      project_id: Ecto.UUID.generate(),
      user_id: Ecto.UUID.generate()
    })
  end

  defp valid_attrs(attrs) do
    Map.merge(
      %{
        filename: "draft-task.md",
        body: "# Draft task\n\nTask body"
      },
      attrs
    )
  end

  describe "create_changeset/2" do
    test "requires ownership, filename, and body" do
      changeset = Artifact.create_changeset(struct(Artifact), %{})

      assert %{
               project_id: ["can't be blank"],
               user_id: ["can't be blank"],
               filename: ["can't be blank"],
               body: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "accepts Markdown and JSON filename/body artifacts" do
      markdown_changeset = Artifact.create_changeset(artifact(), valid_attrs(%{}))

      json_changeset =
        Artifact.create_changeset(
          artifact(),
          valid_attrs(%{filename: "result.json", body: ~s({"status":"ok"})})
        )

      assert markdown_changeset.valid?
      assert json_changeset.valid?
      assert get_change(markdown_changeset, :filename) == "draft-task.md"
      assert get_change(json_changeset, :body) == ~s({"status":"ok"})
    end

    test "keeps ownership scoped to the artifact" do
      replacement_project_id = Ecto.UUID.generate()
      replacement_user_id = Ecto.UUID.generate()

      changeset =
        Artifact.create_changeset(
          artifact(),
          valid_attrs(%{
            project_id: replacement_project_id,
            user_id: replacement_user_id
          })
        )

      assert changeset.changes == %{
               filename: "draft-task.md",
               body: "# Draft task\n\nTask body"
             }
    end
  end
end
