defmodule SacrumWeb.Graphql.ArtifactsTest do
  use SacrumWeb.ConnCase, async: true

  alias Sacrum.Accounts

  defp graphql(conn, query) do
    post(conn, "/graphql", %{"query" => query})
  end

  defp setup_user_and_project(_context) do
    user = create_user()
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Test Project"})
    %{user: user, project: project}
  end

  defp create_artifact(conn, project_id, attrs) do
    visibility = Map.get(attrs, :visibility, "public")
    title = Map.get(attrs, :title, "Artifact")
    artifact_type = Map.get(attrs, :artifact_type, "note")

    result =
      conn
      |> graphql("""
        mutation {
          createArtifact(
            projectId: "#{project_id}"
            artifactType: "#{artifact_type}"
            title: "#{title}"
            visibility: "#{visibility}"
          ) { id title visibility artifactType }
        }
      """)
      |> json_response(200)

    result["data"]["createArtifact"]
  end

  defp link_artifact(conn, artifact_id, subject_type, subject_id, relationship_kind) do
    result =
      conn
      |> graphql("""
        mutation {
          createArtifactLink(
            artifactId: "#{artifact_id}"
            subjectType: "#{subject_type}"
            subjectId: "#{subject_id}"
            relationshipKind: "#{relationship_kind}"
          ) { id }
        }
      """)
      |> json_response(200)

    result["data"]["createArtifactLink"]
  end

  describe "task artifacts" do
    setup [:setup_user_and_project]

    test "returns public artifacts linked to the task and hides internal artifacts",
         %{conn: conn, user: user, project: project} do
      {:ok, task} =
        Accounts.Tasks.insert(user.id, project.id, %{title: "Ticket", level: "ticket"})

      conn = authenticate(conn, user)

      public_artifact =
        create_artifact(conn, project.id, %{
          title: "Public Artifact",
          visibility: "public",
          artifact_type: "note"
        })

      assert public_artifact["visibility"] == "public"

      internal_artifact =
        create_artifact(conn, project.id, %{
          title: "Internal Artifact",
          visibility: "internal",
          artifact_type: "note"
        })

      assert internal_artifact["visibility"] == "internal"

      assert %{"id" => _} =
               link_artifact(conn, public_artifact["id"], "task", task.id, "attached_to")

      assert %{"id" => _} =
               link_artifact(conn, internal_artifact["id"], "task", task.id, "attached_to")

      result =
        build_conn()
        |> authenticate(user)
        |> graphql("""
          { task(id: "#{task.id}") {
              id
              artifacts { id title visibility }
            }
          }
        """)
        |> json_response(200)

      artifacts = result["data"]["task"]["artifacts"]
      ids = Enum.map(artifacts, & &1["id"])

      assert public_artifact["id"] in ids
      refute internal_artifact["id"] in ids
      assert Enum.all?(artifacts, &(&1["visibility"] == "public"))
    end
  end

  describe "task_section artifacts" do
    setup [:setup_user_and_project]

    test "returns public artifacts linked to a testing_criterion section",
         %{conn: conn, user: user, project: project} do
      {:ok, task} =
        Accounts.Tasks.insert(user.id, project.id, %{title: "Ticket", level: "ticket"})

      {:ok, section} =
        Accounts.Sections.insert(user.id, %{
          task_id: task.id,
          project_id: project.id,
          section_type: "testing_criterion",
          content: "Behavior must be X"
        })

      conn = authenticate(conn, user)

      evidence_artifact =
        create_artifact(conn, project.id, %{
          title: "Evidence",
          visibility: "public",
          artifact_type: "test_result"
        })

      internal_artifact =
        create_artifact(conn, project.id, %{
          title: "Internal Notes",
          visibility: "internal",
          artifact_type: "note"
        })

      assert %{"id" => _} =
               link_artifact(
                 conn,
                 evidence_artifact["id"],
                 "task_section",
                 section.id,
                 "evidence_for"
               )

      assert %{"id" => _} =
               link_artifact(
                 conn,
                 internal_artifact["id"],
                 "task_section",
                 section.id,
                 "evidence_for"
               )

      result =
        build_conn()
        |> authenticate(user)
        |> graphql("""
          { task(id: "#{task.id}") {
              sections {
                id
                sectionType
                artifacts { id title visibility }
              }
            }
          }
        """)
        |> json_response(200)

      [section_payload] = result["data"]["task"]["sections"]
      assert section_payload["sectionType"] == "testing_criterion"

      artifacts = section_payload["artifacts"]
      ids = Enum.map(artifacts, & &1["id"])

      assert evidence_artifact["id"] in ids
      refute internal_artifact["id"] in ids
      assert Enum.all?(artifacts, &(&1["visibility"] == "public"))
    end
  end
end
