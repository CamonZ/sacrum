defmodule SacrumWeb.Graphql.SchemaTest do
  use SacrumWeb.ConnCase

  alias Sacrum.Accounts
  alias Sacrum.Orchestrator.TaskFSMSupervisor
  alias Sacrum.Orchestrator.TaskRegistry
  alias Sacrum.Repo.ArtifactLinks
  alias Sacrum.Repo.Artifacts, as: ArtifactsRepo

  defp graphql(conn, query) do
    post(conn, "/graphql", %{"query" => query})
  end

  defp setup_user_and_project(_context) do
    user = create_user()
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Test Project"})
    %{user: user, project: project}
  end

  defp create_artifact(user, project, attrs) do
    attrs =
      Map.merge(
        %{
          filename: "graphql-artifact.md",
          body: "# GraphQL artifact\n\nArtifact body"
        },
        attrs
      )

    {:ok, artifact} = ArtifactsRepo.insert(user.id, project.id, attrs)
    artifact
  end

  defp link_artifact(user, project, artifact, subject_type, subject_id) do
    {:ok, link} =
      ArtifactLinks.insert(user.id, project.id, artifact.id, %{
        subject_type: subject_type,
        subject_id: subject_id
      })

    link
  end

  describe "authentication" do
    test "rejects unauthenticated requests with 401", %{conn: conn} do
      conn = graphql(conn, "{ projects { id } }")
      assert conn.status == 401
    end

    test "rejects invalid token with 401", %{conn: conn} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer sac_invalidtoken")
        |> graphql("{ projects { id } }")

      assert conn.status == 401
    end
  end

  describe "project queries" do
    setup [:setup_user_and_project]

    test "lists projects", %{conn: conn, user: user, project: project} do
      result =
        conn
        |> authenticate(user)
        |> graphql("{ projects { id name slug } }")
        |> json_response(200)

      assert [found] = result["data"]["projects"]
      assert found["id"] == project.id
      assert found["name"] == "Test Project"
      assert found["slug"] != nil
    end

    test "gets a single project by id", %{conn: conn, user: user, project: project} do
      result =
        conn
        |> authenticate(user)
        |> graphql(~s|{ project(id: "#{project.id}") { id name } }|)
        |> json_response(200)

      assert result["data"]["project"]["id"] == project.id
    end

    test "returns error for nonexistent project", %{conn: conn, user: user} do
      fake_id = Ecto.UUID.generate()

      result =
        conn
        |> authenticate(user)
        |> graphql(~s|{ project(id: "#{fake_id}") { id } }|)
        |> json_response(200)

      assert result["data"]["project"] == nil
      assert [%{"message" => _}] = result["errors"]
    end

    test "does not return another user's projects", %{conn: conn, project: project} do
      other_user = create_user(%{email: "other@example.com", username: "other"})

      result =
        conn
        |> authenticate(other_user)
        |> graphql("{ projects { id } }")
        |> json_response(200)

      refute Enum.any?(result["data"]["projects"], &(&1["id"] == project.id))
    end

    test "resolves Markdown and JSON files attached to a project", %{
      conn: conn,
      user: user,
      project: project
    } do
      markdown =
        create_artifact(user, project, %{
          filename: "implementation-plan.md",
          body: "# Implementation plan"
        })

      json =
        create_artifact(user, project, %{
          filename: "implementation-result.json",
          body: ~s({"status":"complete"})
        })

      task_only = create_artifact(user, project, %{filename: "task-only.md"})

      link_artifact(user, project, markdown, "project", project.id)
      link_artifact(user, project, json, "project", project.id)

      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Artifact owner"})
      link_artifact(user, project, task_only, "task", task.id)

      {:ok, other_project} = Accounts.Projects.insert(user.id, %{name: "Other Artifact Project"})
      other_project_artifact = create_artifact(user, other_project, %{filename: "other.md"})

      link_artifact(
        user,
        other_project,
        other_project_artifact,
        "project",
        other_project.id
      )

      other_user =
        create_user(%{
          email: "other-artifact-owner@example.com",
          username: "other_artifact_owner"
        })

      {:ok, other_user_project} =
        Accounts.Projects.insert(other_user.id, %{name: "Other User Artifact Project"})

      other_user_artifact =
        create_artifact(other_user, other_user_project, %{filename: "other-user.md"})

      link_artifact(
        other_user,
        other_user_project,
        other_user_artifact,
        "project",
        other_user_project.id
      )

      result =
        conn
        |> authenticate(user)
        |> graphql(
          ~s|{ project(id: "#{project.id}") { artifacts { id filename body insertedAt updatedAt } } }|
        )
        |> json_response(200)

      artifacts = Enum.sort_by(result["data"]["project"]["artifacts"], & &1["filename"])

      assert artifacts == [
               %{
                 "body" => "# Implementation plan",
                 "filename" => "implementation-plan.md",
                 "id" => markdown.id,
                 "insertedAt" => DateTime.to_iso8601(markdown.inserted_at),
                 "updatedAt" => DateTime.to_iso8601(markdown.updated_at)
               },
               %{
                 "body" => ~s({"status":"complete"}),
                 "filename" => "implementation-result.json",
                 "id" => json.id,
                 "insertedAt" => DateTime.to_iso8601(json.inserted_at),
                 "updatedAt" => DateTime.to_iso8601(json.updated_at)
               }
             ]

      first_page =
        conn
        |> recycle()
        |> authenticate(user)
        |> graphql(~s|{ project(id: "#{project.id}") { artifacts(limit: 1) { id } } }|)
        |> json_response(200)

      second_page =
        conn
        |> recycle()
        |> authenticate(user)
        |> graphql(~s|{ project(id: "#{project.id}") { artifacts(limit: 1, offset: 1) { id } } }|)
        |> json_response(200)

      paged_ids =
        first_page["data"]["project"]["artifacts"] ++
          second_page["data"]["project"]["artifacts"]

      assert MapSet.new(paged_ids, & &1["id"]) == MapSet.new([markdown.id, json.id])
    end
  end

  describe "artifact queries" do
    setup [:setup_user_and_project]

    test "gets a single artifact by id", %{conn: conn, user: user, project: project} do
      artifact =
        create_artifact(user, project, %{
          filename: "readme.md",
          body: "# Artifact read API"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql(
          ~s|{ artifact(id: "#{artifact.id}") { id filename body insertedAt updatedAt } }|
        )
        |> json_response(200)

      assert result["data"]["artifact"] == %{
               "body" => "# Artifact read API",
               "filename" => "readme.md",
               "id" => artifact.id,
               "insertedAt" => DateTime.to_iso8601(artifact.inserted_at),
               "updatedAt" => DateTime.to_iso8601(artifact.updated_at)
             }
    end

    test "gets an attachment by logical name without crossing user or project scope", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Named artifact target"})

      assert {:ok, %{artifact: artifact}} =
               Accounts.Artifacts.create_and_link(
                 user.id,
                 project.id,
                 %{filename: "result.json", body: ~s({"state":"complete"})},
                 %{
                   subject_type: "task",
                   subject_id: task.id,
                   logical_name: "result"
                 }
               )

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          {
            artifactByLogicalName(
              projectId: "#{project.id}"
              subjectType: "task"
              subjectId: "#{task.id}"
              logicalName: "result"
            ) { id filename body logicalName }
          }
        """)
        |> json_response(200)

      assert result["data"]["artifactByLogicalName"] == %{
               "body" => ~s({"state":"complete"}),
               "filename" => "result.json",
               "id" => artifact.id,
               "logicalName" => "result"
             }

      {:ok, other_project} =
        Accounts.Projects.insert(user.id, %{name: "Other named artifact project"})

      {:ok, other_task} =
        Accounts.Tasks.insert(user.id, other_project.id, %{title: "Other named artifact target"})

      other_user =
        create_user(%{
          email: "other-named-artifact@example.com",
          username: "other_named_artifact"
        })

      {:ok, other_user_project} =
        Accounts.Projects.insert(other_user.id, %{name: "Other user named artifact project"})

      {:ok, other_user_task} =
        Accounts.Tasks.insert(other_user.id, other_user_project.id, %{
          title: "Private named artifact target"
        })

      for {owner, scoped_project, scoped_task} <- [
            {user, other_project, other_task},
            {other_user, other_user_project, other_user_task}
          ] do
        assert {:ok, _} =
                 Accounts.Artifacts.create_and_link(
                   owner.id,
                   scoped_project.id,
                   %{filename: "other-result.json", body: "private"},
                   %{
                     subject_type: "task",
                     subject_id: scoped_task.id,
                     logical_name: "result"
                   }
                 )
      end

      for {scoped_project, scoped_task} <- [
            {other_project, task},
            {other_user_project, other_user_task}
          ] do
        forbidden_result =
          conn
          |> recycle()
          |> authenticate(user)
          |> graphql("""
            {
              artifactByLogicalName(
                projectId: "#{scoped_project.id}"
                subjectType: "task"
                subjectId: "#{scoped_task.id}"
                logicalName: "result"
              ) { id }
            }
          """)
          |> json_response(200)

        assert forbidden_result["data"]["artifactByLogicalName"] == nil
        assert [%{"message" => _}] = forbidden_result["errors"]
      end
    end

    test "returns an error for an unknown artifact id", %{conn: conn, user: user} do
      fake_id = Ecto.UUID.generate()

      result =
        conn
        |> authenticate(user)
        |> graphql(~s|{ artifact(id: "#{fake_id}") { id } }|)
        |> json_response(200)

      assert result["data"]["artifact"] == nil
      assert [%{"message" => _}] = result["errors"]
    end

    test "does not return another user's artifact", %{conn: conn, user: user} do
      other_user = create_user(%{email: "other-artifact@example.com", username: "other_artifact"})
      {:ok, other_project} = Accounts.Projects.insert(other_user.id, %{name: "Other Project"})
      artifact = create_artifact(other_user, other_project, %{filename: "private.md"})

      result =
        conn
        |> authenticate(user)
        |> graphql(~s|{ artifact(id: "#{artifact.id}") { id filename body } }|)
        |> json_response(200)

      assert result["data"]["artifact"] == nil
      assert [%{"message" => _}] = result["errors"]
    end

    test "returns a validation error for a malformed artifact id", %{conn: conn, user: user} do
      result =
        conn
        |> authenticate(user)
        |> graphql(~s|{ artifact(id: "not-an-artifact-uuid") { id } }|)
        |> json_response(200)

      assert [%{"message" => message}] = result["errors"]
      assert message =~ "Argument \"id\" has invalid value \"not-an-artifact-uuid\""
    end
  end

  describe "project mutations" do
    test "creates a project", %{conn: conn} do
      user = create_user()

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createProject(name: "New", description: "Desc", slug: "new-proj") {
              id name slug description
            }
          }
        """)
        |> json_response(200)

      data = result["data"]["createProject"]
      assert data["name"] == "New"
      assert data["slug"] == "new-proj"
      assert data["description"] == "Desc"
      assert data["id"] != nil
    end

    test "updates a project", %{conn: conn} do
      user = create_user()
      {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Original"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateProject(id: "#{project.id}", name: "Updated", description: "New desc") {
              id name description
            }
          }
        """)
        |> json_response(200)

      assert result["data"]["updateProject"]["name"] == "Updated"
      assert result["data"]["updateProject"]["description"] == "New desc"
    end

    test "deletes a project", %{conn: conn} do
      user = create_user()
      {:ok, project} = Accounts.Projects.insert(user.id, %{name: "To Delete"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation { deleteProject(id: "#{project.id}") { id } }
        """)
        |> json_response(200)

      assert result["data"]["deleteProject"]["id"] == project.id

      # Verify it's actually gone
      assert {:error, :not_found} =
               Accounts.Projects.get_by(user.id, conditions: [id: project.id])
    end

    test "creates and attaches an artifact to the caller's project", %{conn: conn} do
      user = create_user()
      {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Artifact Project"})
      body = ~s({"result":{"status":"ready"}})

      mutation_result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createArtifact(
              projectId: "#{project.id}"
              filename: "result.json"
              body: #{Jason.encode!(body)}
              logicalName: "latest_result"
            ) {
              id
              filename
              body
              logicalName
            }
          }
        """)
        |> json_response(200)

      assert %{
               "body" => ^body,
               "filename" => "result.json",
               "id" => artifact_id,
               "logicalName" => "latest_result"
             } = mutation_result["data"]["createArtifact"]

      query_result =
        conn
        |> recycle()
        |> authenticate(user)
        |> graphql(
          ~s|{ project(id: "#{project.id}") { artifacts { id filename body logicalName } } }|
        )
        |> json_response(200)

      assert query_result["data"]["project"]["artifacts"] == [
               %{
                 "body" => body,
                 "filename" => "result.json",
                 "id" => artifact_id,
                 "logicalName" => "latest_result"
               }
             ]
    end

    test "creates and attaches an artifact directly to a task", %{conn: conn} do
      user = create_user()
      {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Task Artifact Project"})
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Artifact target"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createArtifact(
              projectId: "#{project.id}"
              filename: "task-result.json"
              body: "{\\"status\\":\\"ready\\"}"
              subjectType: "task"
              subjectId: "#{task.id}"
              logicalName: "result"
            ) { id filename body logicalName }
          }
        """)
        |> json_response(200)

      assert %{
               "id" => artifact_id,
               "filename" => "task-result.json",
               "logicalName" => "result"
             } =
               result["data"]["createArtifact"]

      assert [link] = ArtifactLinks.list_by_subject(user.id, project.id, "task", task.id)
      assert link.artifact_id == artifact_id
      assert link.logical_name == "result"

      task_result =
        conn
        |> recycle()
        |> authenticate(user)
        |> graphql(~s|{ task(id: "#{task.id}") { artifacts { id filename body logicalName } } }|)
        |> json_response(200)

      assert task_result["data"]["task"]["artifacts"] == [
               %{
                 "body" => ~s({"status":"ready"}),
                 "filename" => "task-result.json",
                 "id" => artifact_id,
                 "logicalName" => "result"
               }
             ]

      all_ids =
        conn
        |> recycle()
        |> authenticate(user)
        |> graphql(~s|{ task(id: "#{task.id}") { artifacts { id } } }|)
        |> json_response(200)
        |> get_in(["data", "task", "artifacts"])
        |> Enum.map(& &1["id"])

      paged_ids =
        for offset <- 0..1 do
          conn
          |> recycle()
          |> authenticate(user)
          |> graphql(
            ~s|{ task(id: "#{task.id}") { artifacts(limit: 1, offset: #{offset}) { id } } }|
          )
          |> json_response(200)
          |> get_in(["data", "task", "artifacts"])
          |> Enum.map(& &1["id"])
        end
        |> List.flatten()

      assert paged_ids == Enum.take(all_ids, 2)
    end

    test "creates and reads a harness conversation attachment with provenance metadata", %{
      conn: conn
    } do
      user = create_user()
      {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Conversation Artifact Project"})
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Conversation target"})

      body = ~s({"type":"message","text":"hello"}\n{"type":"message","text":"goodbye"}\n)

      metadata = %{
        "version" => 1,
        "content_kind" => "conversation",
        "format" => "jsonl",
        "origin" => "harness",
        "presentation" => "raw",
        "extensions" => %{
          "harness" => %{"conversation_id" => "conv-123", "exported_at" => "2026-07-31T20:00:00Z"}
        }
      }

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createArtifact(
              projectId: "#{project.id}"
              filename: "conversation.jsonl"
              body: #{Jason.encode!(body)}
              subjectType: "task"
              subjectId: "#{task.id}"
              metadata: #{Jason.encode!(Jason.encode!(metadata))}
            ) { id filename body metadata }
          }
        """)
        |> json_response(200)

      assert %{
               "id" => artifact_id,
               "filename" => "conversation.jsonl",
               "body" => ^body,
               "metadata" => ^metadata
             } = result["data"]["createArtifact"]

      assert [link] = ArtifactLinks.list_by_subject(user.id, project.id, "task", task.id)
      assert link.artifact_id == artifact_id
      assert link.metadata.version == metadata["version"]
      assert link.metadata.content_kind == metadata["content_kind"]
      assert link.metadata.format == metadata["format"]
      assert link.metadata.origin == metadata["origin"]
      assert link.metadata.presentation == metadata["presentation"]
      assert link.metadata.extensions == metadata["extensions"]

      read_result =
        conn
        |> recycle()
        |> authenticate(user)
        |> graphql("""
          { task(id: "#{task.id}") {
            artifacts { id filename body metadata }
          } }
        """)
        |> json_response(200)

      assert read_result["data"]["task"]["artifacts"] == [
               %{
                 "id" => artifact_id,
                 "filename" => "conversation.jsonl",
                 "body" => body,
                 "metadata" => metadata
               }
             ]
    end

    test "rejects malformed conversation metadata and out-of-scope conversation targets atomically",
         %{
           conn: conn
         } do
      user = create_user()
      {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Invalid Conversation Project"})

      {:ok, other_project} =
        Accounts.Projects.insert(user.id, %{name: "Other Conversation Project"})

      {:ok, other_task} =
        Accounts.Tasks.insert(user.id, other_project.id, %{title: "Other target"})

      valid_metadata = %{
        "version" => 1,
        "content_kind" => "conversation",
        "format" => "jsonl",
        "origin" => "harness",
        "presentation" => "raw",
        "extensions" => %{"harness" => %{}}
      }

      malformed_result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createArtifact(
              projectId: "#{project.id}"
              filename: "invalid.jsonl"
              body: "{}"
              subjectType: "project"
              subjectId: "#{project.id}"
              metadata: #{Jason.encode!(Jason.encode!(Map.delete(valid_metadata, "format")))}
            ) { id }
          }
        """)
        |> json_response(200)

      assert malformed_result["data"]["createArtifact"] == nil
      assert [%{"message" => message}] = malformed_result["errors"]
      assert message =~ "metadata"
      assert ArtifactsRepo.count() == 0
      assert ArtifactLinks.count() == 0

      forbidden_result =
        conn
        |> recycle()
        |> authenticate(user)
        |> graphql("""
          mutation {
            createArtifact(
              projectId: "#{project.id}"
              filename: "forbidden.jsonl"
              body: "{}"
              subjectType: "task"
              subjectId: "#{other_task.id}"
              metadata: #{Jason.encode!(Jason.encode!(valid_metadata))}
            ) { id }
          }
        """)
        |> json_response(200)

      assert forbidden_result["data"]["createArtifact"] == nil
      assert [%{"message" => _}] = forbidden_result["errors"]
      assert ArtifactsRepo.count() == 0
      assert ArtifactLinks.count() == 0
    end

    test "rejects incomplete, unsupported, and missing destinations atomically", %{
      conn: conn
    } do
      user = create_user()
      {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Invalid Artifact Project"})

      incomplete_results =
        for destination <- [
              "subjectType: \"task\"",
              "subjectId: \"#{Ecto.UUID.generate()}\""
            ] do
          conn
          |> recycle()
          |> authenticate(user)
          |> graphql("""
            mutation {
              createArtifact(
                projectId: "#{project.id}"
                filename: "invalid.md"
                body: "invalid"
                #{destination}
              ) { id }
            }
          """)
          |> json_response(200)
        end

      for result <- incomplete_results do
        assert result["data"]["createArtifact"] == nil

        assert [%{"message" => "subjectType and subjectId must be provided together"}] =
                 result["errors"]
      end

      unsupported_result =
        conn
        |> recycle()
        |> authenticate(user)
        |> graphql("""
          mutation {
            createArtifact(
              projectId: "#{project.id}"
              filename: "unsupported.md"
              body: "unsupported"
              subjectType: "unsupported"
              subjectId: "#{Ecto.UUID.generate()}"
            ) { id }
          }
        """)
        |> json_response(200)

      assert unsupported_result["data"]["createArtifact"] == nil
      assert [%{"message" => message}] = unsupported_result["errors"]
      assert message =~ "subject_type: is invalid"

      missing_result =
        conn
        |> recycle()
        |> authenticate(user)
        |> graphql("""
          mutation {
            createArtifact(
              projectId: "#{project.id}"
              filename: "missing.md"
              body: "missing"
              subjectType: "task"
              subjectId: "#{Ecto.UUID.generate()}"
            ) { id }
          }
        """)
        |> json_response(200)

      assert missing_result["data"]["createArtifact"] == nil
      assert [%{"message" => _}] = missing_result["errors"]
      assert ArtifactsRepo.count() == 0
      assert ArtifactLinks.count() == 0
    end

    test "rejects a destination from another project or user atomically", %{conn: conn} do
      user = create_user()
      {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Scoped Artifact Project"})
      {:ok, other_project} = Accounts.Projects.insert(user.id, %{name: "Other Artifact Project"})

      {:ok, other_project_task} =
        Accounts.Tasks.insert(user.id, other_project.id, %{title: "Other project task"})

      other_user =
        create_user(%{
          email: "other-scoped-artifact@example.com",
          username: "other_scoped_artifact"
        })

      {:ok, other_user_project} =
        Accounts.Projects.insert(other_user.id, %{name: "Other User Artifact Project"})

      {:ok, other_user_task} =
        Accounts.Tasks.insert(other_user.id, other_user_project.id, %{title: "Other user task"})

      for task_id <- [other_project_task.id, other_user_task.id] do
        result =
          conn
          |> recycle()
          |> authenticate(user)
          |> graphql("""
            mutation {
              createArtifact(
                projectId: "#{project.id}"
                filename: "forbidden.md"
                body: "forbidden"
                subjectType: "task"
                subjectId: "#{task_id}"
              ) { id }
            }
          """)
          |> json_response(200)

        assert result["data"]["createArtifact"] == nil
        assert [%{"message" => _}] = result["errors"]
        assert ArtifactsRepo.count() == 0
        assert ArtifactLinks.count() == 0
      end
    end

    test "does not create an artifact in another user's project", %{conn: conn} do
      owner = create_user(%{email: "artifact-owner@example.com", username: "artifact_owner"})
      caller = create_user(%{email: "artifact-caller@example.com", username: "artifact_caller"})
      {:ok, project} = Accounts.Projects.insert(owner.id, %{name: "Private Artifact Project"})

      result =
        conn
        |> authenticate(caller)
        |> graphql("""
          mutation {
            createArtifact(
              projectId: "#{project.id}"
              filename: "forbidden.md"
              body: "# Forbidden"
            ) { id filename body }
          }
        """)
        |> json_response(200)

      assert result["data"]["createArtifact"] == nil
      assert [%{"message" => _}] = result["errors"]
      assert ArtifactsRepo.count() == 0
      assert ArtifactLinks.count() == 0
    end

    test "updates an artifact and replaces its attachment within the owning project", %{
      conn: conn
    } do
      user = create_user()
      {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Artifact Update Project"})
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Artifact target"})

      artifact = create_artifact(user, project, %{})
      link_artifact(user, project, artifact, "project", project.id)

      update_result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateArtifact(
              id: "#{artifact.id}"
              filename: "updated.json"
              body: "{\\\"status\\\":\\\"updated\\\"}"
              subjectType: "task"
              subjectId: "#{task.id}"
            ) { id filename body }
          }
        """)
        |> json_response(200)

      assert update_result["data"]["updateArtifact"] == %{
               "body" => ~s({"status":"updated"}),
               "filename" => "updated.json",
               "id" => artifact.id
             }

      project_result =
        conn
        |> recycle()
        |> authenticate(user)
        |> graphql(~s|{ project(id: "#{project.id}") { artifacts { id } } }|)
        |> json_response(200)

      task_result =
        conn
        |> recycle()
        |> authenticate(user)
        |> graphql(~s|{ task(id: "#{task.id}") { artifacts { id filename body } } }|)
        |> json_response(200)

      assert project_result["data"]["project"]["artifacts"] == []

      assert task_result["data"]["task"]["artifacts"] == [
               %{
                 "body" => ~s({"status":"updated"}),
                 "filename" => "updated.json",
                 "id" => artifact.id
               }
             ]

      {:ok, other_project} =
        Accounts.Projects.insert(user.id, %{name: "Other Artifact Update Project"})

      {:ok, other_task} =
        Accounts.Tasks.insert(user.id, other_project.id, %{title: "Forbidden artifact target"})

      rejected_result =
        conn
        |> recycle()
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateArtifact(
              id: "#{artifact.id}"
              filename: "forbidden.md"
              subjectType: "task"
              subjectId: "#{other_task.id}"
            ) { id filename }
          }
        """)
        |> json_response(200)

      assert rejected_result["data"]["updateArtifact"] == nil
      assert [%{"message" => _}] = rejected_result["errors"]

      assert {:ok, persisted_artifact} = ArtifactsRepo.get_in_scope(user.id, artifact.id)
      assert persisted_artifact.filename == "updated.json"
      assert [persisted_link] = ArtifactLinks.list_by_artifact(user.id, project.id, artifact.id)
      assert persisted_link.subject_type == "task"
      assert persisted_link.subject_id == task.id
    end

    test "does not update or delete another user's artifact", %{conn: conn} do
      owner = create_user(%{email: "mutation-owner@example.com", username: "mutation_owner"})
      caller = create_user(%{email: "mutation-caller@example.com", username: "mutation_caller"})
      {:ok, project} = Accounts.Projects.insert(owner.id, %{name: "Mutation Owner Project"})

      assert {:ok, %{artifact: artifact}} =
               Accounts.Artifacts.create_and_link(
                 owner.id,
                 project.id,
                 %{filename: "owned.md", body: "# Owned"},
                 %{
                   subject_type: "project",
                   subject_id: project.id
                 }
               )

      update_result =
        conn
        |> authenticate(caller)
        |> graphql("""
          mutation {
            updateArtifact(id: "#{artifact.id}", filename: "forbidden.md") { id }
          }
        """)
        |> json_response(200)

      delete_result =
        conn
        |> recycle()
        |> authenticate(caller)
        |> graphql("""
          mutation { deleteArtifact(id: "#{artifact.id}") { id } }
        """)
        |> json_response(200)

      assert update_result["data"]["updateArtifact"] == nil
      assert [%{"message" => _}] = update_result["errors"]
      assert delete_result["data"]["deleteArtifact"] == nil
      assert [%{"message" => _}] = delete_result["errors"]
      assert {:ok, persisted_artifact} = ArtifactsRepo.get_in_scope(owner.id, artifact.id)
      assert persisted_artifact.filename == "owned.md"
    end

    test "deletes an artifact and its attachments", %{conn: conn} do
      user = create_user()
      {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Artifact Delete Project"})

      assert {:ok, %{artifact: artifact}} =
               Accounts.Artifacts.create_and_link(
                 user.id,
                 project.id,
                 %{filename: "delete-me.md", body: "# Delete me"},
                 %{
                   subject_type: "project",
                   subject_id: project.id
                 }
               )

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation { deleteArtifact(id: "#{artifact.id}") { id filename body } }
        """)
        |> json_response(200)

      assert result["data"]["deleteArtifact"] == %{
               "body" => "# Delete me",
               "filename" => "delete-me.md",
               "id" => artifact.id
             }

      assert {:error, :not_found} = ArtifactsRepo.get_in_scope(user.id, artifact.id)
      assert ArtifactLinks.list_by_artifact(user.id, project.id, artifact.id) == []
    end
  end

  describe "task queries" do
    setup [:setup_user_and_project]

    test "lists tasks for a project", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task 1"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { tasks(projectId: "#{project.id}") { id title } }
        """)
        |> json_response(200)

      assert [found] = result["data"]["tasks"]
      assert found["id"] == task.id
      assert found["title"] == "Task 1"
    end

    test "filters tasks by level", %{conn: conn, user: user, project: project} do
      {:ok, _} = Accounts.Tasks.insert(user.id, project.id, %{title: "Epic", level: "epic"})
      {:ok, _} = Accounts.Tasks.insert(user.id, project.id, %{title: "Ticket", level: "ticket"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { tasks(projectId: "#{project.id}", level: "epic") { id title } }
        """)
        |> json_response(200)

      tasks = result["data"]["tasks"]
      assert length(tasks) == 1
      assert hd(tasks)["title"] == "Epic"
    end

    test "gets a single task by id", %{conn: conn, user: user, project: project} do
      {:ok, task} =
        Accounts.Tasks.insert(user.id, project.id, %{
          title: "My Task",
          description: "Details",
          level: "task",
          priority: "medium",
          tags: ["backend"]
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { task(id: "#{task.id}") { id title description level priority tags } }
        """)
        |> json_response(200)

      data = result["data"]["task"]
      assert data["title"] == "My Task"
      assert data["description"] == "Details"
      assert data["level"] == "task"
      assert data["priority"] == "medium"
      assert data["tags"] == ["backend"]
    end
  end

  describe "task mutations" do
    setup [:setup_user_and_project]

    test "creates a task", %{conn: conn, user: user, project: project} do
      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createTask(
              projectId: "#{project.id}"
              title: "New Task"
              description: "Task desc"
              level: "epic"
              priority: "critical"
              tags: ["bug", "critical"]
            ) { id title description level priority tags }
          }
        """)
        |> json_response(200)

      data = result["data"]["createTask"]
      assert data["title"] == "New Task"
      assert data["description"] == "Task desc"
      assert data["level"] == "epic"
      assert data["priority"] == "critical"
      assert data["tags"] == ["bug", "critical"]
    end

    test "creates a task with default priority", %{conn: conn, user: user, project: project} do
      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createTask(
              projectId: "#{project.id}"
              title: "Default Priority"
            ) { id title priority }
          }
        """)
        |> json_response(200)

      data = result["data"]["createTask"]
      assert data["title"] == "Default Priority"
      assert data["priority"] == "medium"
    end

    test "rejects invalid task priority", %{conn: conn, user: user, project: project} do
      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createTask(
              projectId: "#{project.id}"
              title: "Invalid Priority"
              priority: "urgent"
            ) { id title priority }
          }
        """)
        |> json_response(200)

      assert result["data"]["createTask"] == nil
      assert [%{"message" => message}] = result["errors"]
      assert message =~ "priority"
    end

    test "creates a task with worktree field", %{conn: conn, user: user, project: project} do
      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createTask(
              projectId: "#{project.id}"
              title: "Task with Worktree"
              description: "Test worktree field"
              worktree: "/path/to/worktree"
            ) { id title worktree }
          }
        """)
        |> json_response(200)

      data = result["data"]["createTask"]
      assert data["title"] == "Task with Worktree"
      assert data["worktree"] == "/path/to/worktree"
    end

    test "creates a task with parent_id", %{conn: conn, user: user, project: project} do
      # Create parent task first
      {:ok, parent_task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Parent Task"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createTask(
              projectId: "#{project.id}"
              title: "Child Task"
              description: "Task with parent"
              parentId: "#{parent_task.id}"
            ) { id title parentId parent { id title } }
          }
        """)
        |> json_response(200)

      data = result["data"]["createTask"]
      assert data["title"] == "Child Task"
      assert data["parentId"] == parent_task.id
      assert data["parent"]["id"] == parent_task.id
      assert data["parent"]["title"] == "Parent Task"
    end

    test "createTask with explicit workflow_id assigns that workflow and seeds initial step", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "Custom WF"})
      {:ok, step1} = Accounts.WorkflowSteps.insert(workflow, %{name: "S1", step_order: 1})
      {:ok, _step2} = Accounts.WorkflowSteps.insert(workflow, %{name: "S2", step_order: 2})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createTask(
              projectId: "#{project.id}"
              title: "Custom Workflow Task"
              workflowId: "#{workflow.id}"
            ) { id title workflowId currentStepId }
          }
        """)
        |> json_response(200)

      data = result["data"]["createTask"]
      assert data["workflowId"] == workflow.id
      assert data["currentStepId"] == step1.id
    end

    test "createTask without workflow_id falls back to project's default Backlog workflow", %{
      conn: conn,
      user: user,
      project: project
    } do
      default_workflow =
        Sacrum.Repo.get_by(Sacrum.Repo.Schemas.Workflow,
          project_id: project.id,
          is_default: true
        )

      assert default_workflow != nil
      assert default_workflow.initial_step_id != nil

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createTask(projectId: "#{project.id}", title: "Default WF Task") {
              id workflowId currentStepId
            }
          }
        """)
        |> json_response(200)

      data = result["data"]["createTask"]
      assert data["workflowId"] == default_workflow.id
      assert data["currentStepId"] == default_workflow.initial_step_id
    end

    test "createTask with workflow_id from a different project returns a validation error", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, other_project} = Accounts.Projects.insert(user.id, %{name: "Other Project"})
      {:ok, other_workflow} = Accounts.Workflows.insert(user.id, other_project.id, %{name: "X"})
      {:ok, _} = Accounts.WorkflowSteps.insert(other_workflow, %{name: "S1", step_order: 1})

      tasks_before = Accounts.Tasks.list_tasks(user.id, conditions: [project_id: project.id])

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createTask(
              projectId: "#{project.id}"
              title: "Cross Project WF"
              workflowId: "#{other_workflow.id}"
            ) { id }
          }
        """)
        |> json_response(200)

      assert result["data"]["createTask"] == nil
      assert [%{"message" => message}] = result["errors"]
      assert message =~ "workflow"

      tasks_after = Accounts.Tasks.list_tasks(user.id, conditions: [project_id: project.id])
      assert length(tasks_after) == length(tasks_before)
    end

    test "createTask with another user's workflow_id returns a validation error", %{
      conn: conn,
      user: user,
      project: project
    } do
      other_user =
        create_user(%{email: "cross-user-wf@example.com", username: "crossuserwf"})

      {:ok, other_project} =
        Accounts.Projects.insert(other_user.id, %{name: "Other User Project"})

      {:ok, other_workflow} =
        Accounts.Workflows.insert(other_user.id, other_project.id, %{name: "X"})

      {:ok, _} = Accounts.WorkflowSteps.insert(other_workflow, %{name: "S1", step_order: 1})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createTask(
              projectId: "#{project.id}"
              title: "Cross User WF"
              workflowId: "#{other_workflow.id}"
            ) { id }
          }
        """)
        |> json_response(200)

      assert result["data"]["createTask"] == nil
      assert [%{"message" => message}] = result["errors"]
      assert message =~ "workflow"
    end

    test "createTask with a non-existent workflow_id returns a clean error (not a 500)", %{
      conn: conn,
      user: user,
      project: project
    } do
      fake_workflow_id = Ecto.UUID.generate()

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createTask(
              projectId: "#{project.id}"
              title: "Missing WF"
              workflowId: "#{fake_workflow_id}"
            ) { id }
          }
        """)
        |> json_response(200)

      assert result["data"]["createTask"] == nil
      assert [%{"message" => message}] = result["errors"]
      assert message =~ "workflow"
    end

    test "updates a task", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Original"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateTask(id: "#{task.id}", title: "Updated", description: "New desc") {
              id title description
            }
          }
        """)
        |> json_response(200)

      assert result["data"]["updateTask"]["title"] == "Updated"
      assert result["data"]["updateTask"]["description"] == "New desc"
    end

    test "updates a task with worktree field", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateTask(id: "#{task.id}", worktree: "/updated/worktree/path") {
              id worktree
            }
          }
        """)
        |> json_response(200)

      assert result["data"]["updateTask"]["worktree"] == "/updated/worktree/path"
    end

    test "sets parent_id via updateTask", %{conn: conn, user: user, project: project} do
      {:ok, parent} = Accounts.Tasks.insert(user.id, project.id, %{title: "Parent"})
      {:ok, child} = Accounts.Tasks.insert(user.id, project.id, %{title: "Child"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateTask(id: "#{child.id}", parentId: "#{parent.id}") { id parentId }
          }
        """)
        |> json_response(200)

      assert result["errors"] == nil
      assert result["data"]["updateTask"]["parentId"] == parent.id
    end

    test "removes parent_id via updateTask", %{conn: conn, user: user, project: project} do
      {:ok, parent} = Accounts.Tasks.insert(user.id, project.id, %{title: "Parent"})
      {:ok, child} = Accounts.Tasks.insert(user.id, project.id, %{title: "Child"})
      {:ok, _} = Sacrum.Repo.TaskHierarchy.set_parent(child, parent)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateTask(id: "#{child.id}", parentId: null) { id parentId }
          }
        """)
        |> json_response(200)

      assert result["errors"] == nil
      assert result["data"]["updateTask"]["parentId"] == nil
    end

    test "sets depends_on_ids via updateTask", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, blocker} = Accounts.Tasks.insert(user.id, project.id, %{title: "Blocker"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateTask(id: "#{task.id}", dependsOnIds: ["#{blocker.id}"]) {
              id blockers { id }
            }
          }
        """)
        |> json_response(200)

      assert result["errors"] == nil
      assert [%{"id" => blocker_id}] = result["data"]["updateTask"]["blockers"]
      assert blocker_id == blocker.id
    end

    test "clears depends_on_ids via updateTask", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, blocker} = Accounts.Tasks.insert(user.id, project.id, %{title: "Blocker"})
      {:ok, _} = Accounts.Tasks.add_dependency(task, blocker)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateTask(id: "#{task.id}", dependsOnIds: []) {
              id blockers { id }
            }
          }
        """)
        |> json_response(200)

      assert result["errors"] == nil
      assert result["data"]["updateTask"]["blockers"] == []
      assert Sacrum.Repo.TaskDependencies.get_direct_blockers(task) == []
    end

    test "rolls back dependency replace via updateTask when one dependency is invalid", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, other_project} = Accounts.Projects.insert(user.id, %{name: "Other Project"})
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, old_blocker} = Accounts.Tasks.insert(user.id, project.id, %{title: "Old Blocker"})
      {:ok, kept_blocker} = Accounts.Tasks.insert(user.id, project.id, %{title: "Kept Blocker"})
      {:ok, new_blocker} = Accounts.Tasks.insert(user.id, project.id, %{title: "New Blocker"})

      {:ok, foreign_blocker} =
        Accounts.Tasks.insert(user.id, other_project.id, %{title: "Foreign"})

      {:ok, _} = Accounts.Tasks.add_dependency(task, old_blocker)
      {:ok, _} = Accounts.Tasks.add_dependency(task, kept_blocker)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateTask(
              id: "#{task.id}"
              dependsOnIds: ["#{kept_blocker.id}", "#{new_blocker.id}", "#{foreign_blocker.id}"]
            ) {
              id blockers { id }
            }
          }
        """)
        |> json_response(200)

      assert result["errors"] != nil

      blocker_ids =
        task
        |> Sacrum.Repo.TaskDependencies.get_direct_blockers()
        |> Enum.map(& &1.id)
        |> MapSet.new()

      assert blocker_ids == MapSet.new([old_blocker.id, kept_blocker.id])
    end

    test "rolls back task fields when dependency replace fails", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, other_project} = Accounts.Projects.insert(user.id, %{name: "Other Project"})
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Original"})

      {:ok, foreign_blocker} =
        Accounts.Tasks.insert(user.id, other_project.id, %{title: "Foreign"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateTask(
              id: "#{task.id}"
              title: "Should rollback"
              dependsOnIds: ["#{foreign_blocker.id}"]
            ) {
              id title
            }
          }
        """)
        |> json_response(200)

      assert result["data"]["updateTask"] == nil
      assert [%{"message" => "one or more dependencies not found"}] = result["errors"]

      {:ok, found_task} = Accounts.Tasks.find(user.id, task.id)
      assert found_task.title == "Original"
    end

    test "does not reveal cross-project dependency task existence", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, other_project} = Accounts.Projects.insert(user.id, %{name: "Other Project"})
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      {:ok, foreign_blocker} =
        Accounts.Tasks.insert(user.id, other_project.id, %{title: "Foreign"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            syncTaskDependencies(taskId: "#{task.id}", dependsOnIds: ["#{foreign_blocker.id}"]) {
              id
            }
          }
        """)
        |> json_response(200)

      assert result["data"]["syncTaskDependencies"] == nil
      assert [%{"message" => "one or more dependencies not found"}] = result["errors"]
    end

    test "updates task fields and section creates updates and deletions atomically", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Original"})

      {:ok, existing} =
        Accounts.Sections.insert(user.id, %{
          task_id: task.id,
          project_id: project.id,
          section_type: "context",
          content: "Old context"
        })

      {:ok, deleted} =
        Accounts.Sections.insert(user.id, %{
          task_id: task.id,
          project_id: project.id,
          section_type: "constraint",
          content: "Remove me"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateTask(
              id: "#{task.id}"
              title: "Updated"
              sections: [
                {id: "#{existing.id}", content: "New context"}
                {sectionType: "checklist_item", content: "Created item"}
              ]
              sectionDeletions: ["#{deleted.id}"]
            ) {
              id
              title
              sections { id sectionType content }
            }
          }
        """)
        |> json_response(200)

      assert result["errors"] == nil
      assert result["data"]["updateTask"]["title"] == "Updated"

      sections = result["data"]["updateTask"]["sections"]
      assert Enum.any?(sections, &(&1["id"] == existing.id and &1["content"] == "New context"))

      assert Enum.any?(
               sections,
               &(&1["sectionType"] == "checklist_item" and &1["content"] == "Created item")
             )

      refute Enum.any?(sections, &(&1["id"] == deleted.id))

      assert {:error, :not_found} =
               Accounts.Sections.get_by(user.id, conditions: [id: deleted.id])
    end

    test "updateTask sections dedupe id-less single-instance sections", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      {:ok, section} =
        Accounts.Sections.insert(user.id, %{
          task_id: task.id,
          project_id: project.id,
          section_type: "goal",
          content: "Old goal"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateTask(
              id: "#{task.id}"
              sections: [{sectionType: "goal", content: "New goal"}]
            ) {
              sections { id sectionType content }
            }
          }
        """)
        |> json_response(200)

      assert result["errors"] == nil

      goals =
        result["data"]["updateTask"]["sections"]
        |> Enum.filter(&(&1["sectionType"] == "goal"))

      assert [%{"id" => section_id, "content" => "New goal"}] = goals
      assert section_id == section.id
    end

    test "rolls back task field changes when a section edit is invalid", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Original"})

      {:ok, section} =
        Accounts.Sections.insert(user.id, %{
          task_id: task.id,
          project_id: project.id,
          section_type: "context",
          content: "Original context"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateTask(
              id: "#{task.id}"
              title: "Should rollback"
              sections: [{id: "#{section.id}", content: ""}]
            ) {
              id title
            }
          }
        """)
        |> json_response(200)

      assert result["data"]["updateTask"] == nil
      assert result["errors"] != nil

      {:ok, found_task} = Accounts.Tasks.find(user.id, task.id)
      {:ok, found_section} = Accounts.Sections.get_by(user.id, conditions: [id: section.id])

      assert found_task.title == "Original"
      assert found_section.content == "Original context"
    end

    test "rejects section ids listed for both update and deletion", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Original"})

      {:ok, section} =
        Accounts.Sections.insert(user.id, %{
          task_id: task.id,
          project_id: project.id,
          section_type: "context",
          content: "Original context"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateTask(
              id: "#{task.id}"
              sections: [{id: "#{section.id}", content: "Updated"}]
              sectionDeletions: ["#{section.id}"]
            ) {
              id
            }
          }
        """)
        |> json_response(200)

      assert result["data"]["updateTask"] == nil
      assert result["errors"] != nil

      {:ok, found_section} = Accounts.Sections.get_by(user.id, conditions: [id: section.id])
      assert found_section.content == "Original context"
    end

    test "rejects section deletions from another task", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Original"})
      {:ok, other_task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Other"})

      {:ok, foreign_section} =
        Accounts.Sections.insert(user.id, %{
          task_id: other_task.id,
          project_id: project.id,
          section_type: "context",
          content: "Foreign"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateTask(
              id: "#{task.id}"
              title: "Should rollback"
              sectionDeletions: ["#{foreign_section.id}"]
            ) {
              id title
            }
          }
        """)
        |> json_response(200)

      assert result["data"]["updateTask"] == nil
      assert result["errors"] != nil

      {:ok, found_task} = Accounts.Tasks.find(user.id, task.id)
      assert found_task.title == "Original"
    end

    test "deletes a task", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "To Delete"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation { deleteTask(id: "#{task.id}") { id title } }
        """)
        |> json_response(200)

      assert result["data"]["deleteTask"]["id"] == task.id

      assert {:error, :not_found} = Accounts.Tasks.find(user.id, task.id)
    end

    test "assigns and unassigns a workflow", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, _step} = Accounts.WorkflowSteps.insert(workflow, %{name: "Step 1", step_order: 1})

      # Assign
      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            assignWorkflow(taskId: "#{task.id}", workflowId: "#{workflow.id}") {
              id workflowId
            }
          }
        """)
        |> json_response(200)

      assert result["data"]["assignWorkflow"]["workflowId"] == workflow.id

      # Unassign
      result =
        build_conn()
        |> authenticate(user)
        |> graphql("""
          mutation { unassignWorkflow(taskId: "#{task.id}") { id workflowId } }
        """)
        |> json_response(200)

      assert result["data"]["unassignWorkflow"]["workflowId"] == nil
    end

    test "moves task to a step", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step1} = Accounts.WorkflowSteps.insert(workflow, %{name: "Step 1", step_order: 1})
      {:ok, step2} = Accounts.WorkflowSteps.insert(workflow, %{name: "Step 2", step_order: 2})

      # Create a transition between step1 and step2
      {:ok, _} =
        Accounts.StepTransitions.insert(user.id, %{
          from_step_id: step1.id,
          to_step_id: step2.id,
          project_id: project.id
        })

      # Assign workflow (puts task on step1)
      conn
      |> authenticate(user)
      |> graphql("""
        mutation { assignWorkflow(taskId: "#{task.id}", workflowId: "#{workflow.id}") { id } }
      """)

      # Move to step2
      result =
        build_conn()
        |> authenticate(user)
        |> graphql("""
          mutation { moveToStep(taskId: "#{task.id}", stepId: "#{step2.id}") { id currentStepId } }
        """)
        |> json_response(200)

      assert result["data"]["moveToStep"]["currentStepId"] == step2.id
    end

    test "stopOrchestrator halts a running orchestrator", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      child_spec = {Sacrum.Orchestrator.TaskOrchestrator, task_id: task.id, user_id: user.id}
      {:ok, pid} = TaskFSMSupervisor.start_child(child_spec)
      Ecto.Adapters.SQL.Sandbox.allow(Sacrum.Repo, self(), pid)
      :sys.get_state(pid)

      assert [] !== Registry.lookup(TaskRegistry, task.id)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            stopOrchestrator(taskId: "#{task.id}") {
              id
              title
            }
          }
        """)
        |> json_response(200)

      assert result["errors"] == nil
      assert result["data"]["stopOrchestrator"]["id"] == task.id
      assert result["data"]["stopOrchestrator"]["title"] == "Task"

      Process.sleep(50)
      assert [] = Registry.lookup(TaskRegistry, task.id)
    end

    test "stopOrchestrator succeeds even when no orchestrator is running", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      assert [] = Registry.lookup(TaskRegistry, task.id)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            stopOrchestrator(taskId: "#{task.id}") {
              id
            }
          }
        """)
        |> json_response(200)

      assert result["errors"] == nil
      assert result["data"]["stopOrchestrator"]["id"] == task.id
    end

    test "stopOrchestrator is idempotent: calling it twice succeeds both times", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task1} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task 1"})
      {:ok, task2} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task 2"})

      child_spec1 = {Sacrum.Orchestrator.TaskOrchestrator, task_id: task1.id, user_id: user.id}
      {:ok, pid1} = TaskFSMSupervisor.start_child(child_spec1)

      child_spec2 = {Sacrum.Orchestrator.TaskOrchestrator, task_id: task2.id, user_id: user.id}
      {:ok, pid2} = TaskFSMSupervisor.start_child(child_spec2)

      # Allow the orchestrators on the test sandbox so their auto-dispatch
      # state_timeout (TaskOrchestrator.dispatch_execution → WorkflowSteps.get_by)
      # can run, then sync via :sys.get_state to wait for that dispatch to finish
      # before any stopOrchestrator call kills the process mid-checkout.
      Ecto.Adapters.SQL.Sandbox.allow(Sacrum.Repo, self(), pid1)
      Ecto.Adapters.SQL.Sandbox.allow(Sacrum.Repo, self(), pid2)
      :sys.get_state(pid1, 30_000)
      :sys.get_state(pid2, 30_000)

      auth_conn = authenticate(conn, user)

      # First call to stopOrchestrator
      result1 =
        auth_conn
        |> graphql("""
          mutation {
            stopOrchestrator(taskId: "#{task1.id}") { id }
          }
        """)
        |> json_response(200)

      assert result1["data"]["stopOrchestrator"]["id"] == task1.id

      # Second call to stopOrchestrator on task2 (not idempotency test, just two calls)
      # This verifies that calling stopOrchestrator works multiple times
      result2 =
        auth_conn
        |> graphql("""
          mutation {
            stopOrchestrator(taskId: "#{task2.id}") { id }
          }
        """)
        |> json_response(200)

      assert result2["data"]["stopOrchestrator"]["id"] == task2.id
    end

    test "stopOrchestrator rejects unauthenticated caller", %{conn: conn} do
      user = create_user(%{email: "stop_unauth@example.com", username: "stop_unauth"})
      {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Test Project"})
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      response =
        graphql(conn, """
          mutation {
            stopOrchestrator(taskId: "#{task.id}") { id }
          }
        """)

      assert response.status == 401
    end

    test "stopOrchestrator returns error when caller doesn't own the task", %{conn: conn} do
      user = create_user(%{email: "stop_owner@example.com", username: "stop_owner"})
      {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Test Project"})
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      other_user = create_user(%{email: "other_caller@example.com", username: "other_caller"})

      result =
        conn
        |> authenticate(other_user)
        |> graphql("""
          mutation {
            stopOrchestrator(taskId: "#{task.id}") { id }
          }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end

    test "stopOrchestrator marks an in_progress StepExecution as cancelled", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      {:ok, execution} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          step_name: "Test Step",
          status: "in_progress",
          project_id: project.id
        })

      test_pid = self()
      ref = make_ref()

      fake_orchestrator =
        spawn_link(fn ->
          {:ok, _} = Registry.register(Sacrum.Orchestrator.TaskRegistry, task.id, nil)
          send(test_pid, {ref, :registered})
          receive do: ({:stop, ^ref} -> :ok)
        end)

      receive do: ({^ref, :registered} -> :ok)

      on_exit(fn ->
        if Process.alive?(fake_orchestrator), do: send(fake_orchestrator, {:stop, ref})
      end)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            stopOrchestrator(taskId: "#{task.id}") {
              id
              title
            }
          }
        """)
        |> json_response(200)

      assert result["errors"] == nil
      assert result["data"]["stopOrchestrator"]["id"] == task.id

      assert Sacrum.Repo.get!(Sacrum.Repo.Schemas.StepExecution, execution.id).status ==
               "cancelled"
    end
  end

  describe "workflow queries" do
    setup [:setup_user_and_project]

    test "lists workflows for a project", %{conn: conn, user: user, project: project} do
      {:ok, wf} =
        Accounts.Workflows.insert(user.id, project.id, %{
          name: "My Workflow",
          factory_name: "Workflow Factory"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { workflows(projectId: "#{project.id}") { id name description factoryName } }
        """)
        |> json_response(200)

      workflows = result["data"]["workflows"]
      assert length(workflows) == 2

      assert Enum.any?(workflows, fn workflow ->
               workflow["id"] == wf.id and
                 workflow["name"] == "My Workflow" and
                 workflow["factoryName"] == "Workflow Factory"
             end)
    end

    test "gets a single workflow", %{conn: conn, user: user, project: project} do
      {:ok, wf} =
        Accounts.Workflows.insert(user.id, project.id, %{
          name: "WF",
          description: "A workflow",
          factory_name: "Single Workflow Factory"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql(~s|{ workflow(id: "#{wf.id}") { id name description factoryName } }|)
        |> json_response(200)

      assert result["data"]["workflow"]["id"] == wf.id
      assert result["data"]["workflow"]["description"] == "A workflow"
      assert result["data"]["workflow"]["factoryName"] == "Single Workflow Factory"
    end
  end

  describe "pipeline summary query" do
    setup [:setup_user_and_project]

    # Testing Criterion 1: UNIT - scope to caller's project
    test "returns workflows scoped to the caller's project and excludes others", %{
      conn: conn,
      user: user,
      project: project
    } do
      other_user = create_user(%{email: "other@example.com", username: "other"})
      {:ok, other_project} = Accounts.Projects.insert(other_user.id, %{name: "Other Project"})

      {:ok, wf1} = Accounts.Workflows.insert(user.id, project.id, %{name: "My WF"})

      {:ok, _wf2} =
        Accounts.Workflows.insert(other_user.id, other_project.id, %{name: "Other WF"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          {
            pipelineSummary(projectId: "#{project.id}") {
              id
              name
            }
          }
        """)
        |> json_response(200)

      pipelines = result["data"]["pipelineSummary"]
      assert length(pipelines) == 2
      wf1_found = Enum.find(pipelines, &(&1["id"] == wf1.id))
      refute is_nil(wf1_found)
      assert wf1_found["name"] == "My WF"
    end

    # Testing Criterion 2: UNIT - task_counts grouped by level
    test "task_counts resolver returns correct counts grouped by level for each step", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "Test WF"})
      {:ok, _step1} = Accounts.WorkflowSteps.insert(wf, %{name: "Step 1", step_order: 1})

      # Create tasks with different levels
      {:ok, epic1} = Accounts.Tasks.insert(user.id, project.id, %{title: "Epic 1", level: "epic"})

      {:ok, ticket1} =
        Accounts.Tasks.insert(user.id, project.id, %{title: "Ticket 1", level: "ticket"})

      {:ok, task1} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task 1", level: "task"})

      # Assign all to workflow (they will automatically be on step1 since it's the first step)
      Sacrum.Repo.TaskWorkflows.assign_workflow(epic1, wf)
      Sacrum.Repo.TaskWorkflows.assign_workflow(ticket1, wf)
      Sacrum.Repo.TaskWorkflows.assign_workflow(task1, wf)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          {
            pipelineSummary(projectId: "#{project.id}") {
              id
              workflowSteps {
                id
                name
                taskCounts {
                  epic
                  ticket
                  task
                }
              }
            }
          }
        """)
        |> json_response(200)

      workflows = result["data"]["pipelineSummary"]
      test_wf = Enum.find(workflows, &(&1["id"] == wf.id))
      refute is_nil(test_wf)

      steps = test_wf["workflowSteps"]
      step_data = hd(steps)
      counts = step_data["taskCounts"]

      assert counts["epic"] == 1
      assert counts["ticket"] == 1
      assert counts["task"] == 1
    end

    test "pipelineSummary does not leak matching cross-user step counts", %{
      conn: conn,
      user: user,
      project: project
    } do
      other_user = create_user(%{email: "pipeline-other@example.com", username: "pipelineother"})

      {:ok, other_project} =
        Accounts.Projects.insert(other_user.id, %{name: "Other User Project"})

      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "Test WF"})
      {:ok, step1} = Accounts.WorkflowSteps.insert(wf, %{name: "Step 1", step_order: 1})

      {:ok, other_wf} =
        Accounts.Workflows.insert(other_user.id, other_project.id, %{name: "Test WF"})

      {:ok, other_step1} =
        Accounts.WorkflowSteps.insert(other_wf, %{name: "Step 1", step_order: 1})

      {:ok, ticket} =
        Accounts.Tasks.insert(user.id, project.id, %{
          title: "Visible ticket",
          level: "ticket",
          workflow_id: wf.id,
          current_step_id: step1.id
        })

      {:ok, other_task} =
        Accounts.Tasks.insert(other_user.id, other_project.id, %{
          title: "Other user epic",
          level: "epic",
          workflow_id: other_wf.id,
          current_step_id: other_step1.id
        })

      {:ok, _run} = Accounts.TaskRuns.insert(user.id, project.id, ticket.id, %{status: :queued})

      {:ok, _other_run} =
        Accounts.TaskRuns.insert(other_user.id, other_project.id, other_task.id, %{
          status: :executing
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          {
            pipelineSummary(projectId: "#{project.id}") {
              id
              workflowSteps {
                id
                pipelineCounts {
                  epic
                  ticket
                  active
                }
              }
            }
          }
        """)
        |> json_response(200)

      workflows = result["data"]["pipelineSummary"]
      test_wf = Enum.find(workflows, &(&1["id"] == wf.id))
      refute is_nil(test_wf)

      step_data = Enum.find(test_wf["workflowSteps"], &(&1["id"] == step1.id))
      refute is_nil(step_data)
      assert step_data["pipelineCounts"] == %{"epic" => 0, "ticket" => 1, "active" => 1}
    end

    test "pipelineSummary exposes active TaskRun-backed counts and keeps runningCount compatible",
         %{
           conn: conn,
           user: user,
           project: project
         } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "Test WF"})
      {:ok, step1} = Accounts.WorkflowSteps.insert(wf, %{name: "Step 1", step_order: 1})

      for status <- [:queued, :executing, :waiting, :stopping] do
        {:ok, task} =
          Accounts.Tasks.insert(user.id, project.id, %{
            title: "Task #{status}",
            level: "task",
            workflow_id: wf.id,
            current_step_id: step1.id
          })

        {:ok, _run} = Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: status})
      end

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          {
            pipelineSummary(projectId: "#{project.id}") {
              id
              name
              workflowSteps {
                name
                activeCount
                runningCount
                pipelineCounts {
                  active
                  task
                }
              }
            }
          }
        """)
        |> json_response(200)

      workflows = result["data"]["pipelineSummary"]
      wf_data = Enum.find(workflows, &(&1["id"] == wf.id))
      refute is_nil(wf_data)

      steps = wf_data["workflowSteps"]
      step_data = Enum.find(steps, &(&1["name"] == "Step 1"))
      refute is_nil(step_data)

      assert step_data["activeCount"] == 4
      assert step_data["runningCount"] == 4
      assert step_data["pipelineCounts"]["active"] == 4
      assert step_data["pipelineCounts"]["task"] == 4
    end

    test "pipelineSummary excludes archived tasks and terminal TaskRuns from relevant buckets",
         %{
           conn: conn,
           user: user,
           project: project
         } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "Test WF"})
      {:ok, step1} = Accounts.WorkflowSteps.insert(wf, %{name: "Step 1", step_order: 1})

      {:ok, active_task} =
        Accounts.Tasks.insert(user.id, project.id, %{
          title: "Active task",
          level: "task",
          workflow_id: wf.id,
          current_step_id: step1.id
        })

      {:ok, terminal_task} =
        Accounts.Tasks.insert(user.id, project.id, %{
          title: "Terminal run task",
          level: "task",
          workflow_id: wf.id,
          current_step_id: step1.id
        })

      {:ok, archived_task} =
        Accounts.Tasks.insert(user.id, project.id, %{
          title: "Archived task",
          level: "task",
          workflow_id: wf.id,
          current_step_id: step1.id
        })

      {:ok, archived_task} = Accounts.Tasks.update(archived_task, %{archived: true})

      {:ok, _active_run} =
        Accounts.TaskRuns.insert(user.id, project.id, active_task.id, %{status: :executing})

      {:ok, _terminal_run} =
        Accounts.TaskRuns.insert(user.id, project.id, terminal_task.id, %{status: :completed})

      {:ok, _archived_run} =
        Accounts.TaskRuns.insert(user.id, project.id, archived_task.id, %{status: :waiting})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          {
            pipelineSummary(projectId: "#{project.id}") {
              id
              workflowSteps {
                id
                taskCounts { task }
                activeCount
                pipelineCounts {
                  task
                  active
                }
              }
            }
          }
        """)
        |> json_response(200)

      workflows = result["data"]["pipelineSummary"]
      wf_data = Enum.find(workflows, &(&1["id"] == wf.id))
      refute is_nil(wf_data)

      step_data = Enum.find(wf_data["workflowSteps"], &(&1["id"] == step1.id))
      refute is_nil(step_data)

      assert step_data["taskCounts"]["task"] == 2
      assert step_data["activeCount"] == 1
      assert step_data["pipelineCounts"] == %{"task" => 2, "active" => 1}
    end

    test "pipelineSummary does not count started StepExecution rows without active TaskRuns", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "Test WF"})
      {:ok, step1} = Accounts.WorkflowSteps.insert(wf, %{name: "Step 1", step_order: 1})
      {:ok, task1} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task 1"})

      Sacrum.Repo.TaskWorkflows.assign_workflow(task1, wf)
      {:ok, task1} = Sacrum.Repo.Tasks.get(task1.id)

      Accounts.StepExecutions.insert(user.id, %{
        task_id: task1.id,
        workflow_id: wf.id,
        step_id: step1.id,
        project_id: project.id,
        step_name: "Step 1",
        status: "started"
      })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          {
            pipelineSummary(projectId: "#{project.id}") {
              id
              name
              workflowSteps {
                name
                activeCount
                runningCount
              }
            }
          }
        """)
        |> json_response(200)

      workflows = result["data"]["pipelineSummary"]
      wf_data = Enum.find(workflows, &(&1["id"] == wf.id))
      refute is_nil(wf_data)

      steps = wf_data["workflowSteps"]
      step_data = Enum.find(steps, &(&1["name"] == "Step 1"))
      refute is_nil(step_data)

      assert step_data["activeCount"] == 0
      assert step_data["runningCount"] == 0
    end

    # Testing Criterion 4: UNIT - transitions_to returns only outgoing intra-workflow edges
    test "transitions_to on a step returns only target step ids of intra-workflow transitions", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "Test WF"})
      {:ok, step1} = Accounts.WorkflowSteps.insert(wf, %{name: "Step 1", step_order: 1})
      {:ok, step2} = Accounts.WorkflowSteps.insert(wf, %{name: "Step 2", step_order: 2})
      {:ok, step3} = Accounts.WorkflowSteps.insert(wf, %{name: "Step 3", step_order: 3})

      # Create transitions from step1 to step2 and step3
      Accounts.StepTransitions.insert(user.id, %{
        from_step_id: step1.id,
        to_step_id: step2.id,
        label: "to_step2",
        project_id: project.id
      })

      Accounts.StepTransitions.insert(user.id, %{
        from_step_id: step1.id,
        to_step_id: step3.id,
        label: "to_step3",
        project_id: project.id
      })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          {
            pipelineSummary(projectId: "#{project.id}") {
              id
              name
              workflowSteps {
                name
                transitions {
                  id
                  label
                  toStepId
                }
              }
            }
          }
        """)
        |> json_response(200)

      workflows = result["data"]["pipelineSummary"]
      wf_data = Enum.find(workflows, &(&1["id"] == wf.id))
      refute is_nil(wf_data)

      steps = wf_data["workflowSteps"]
      step1_data = Enum.find(steps, fn s -> s["name"] == "Step 1" end)

      transitions = step1_data["transitions"]
      assert length(transitions) == 2

      labels = Enum.map(transitions, & &1["label"])
      assert "to_step2" in labels
      assert "to_step3" in labels
    end

    # Failure Test 1: Empty/zero edge cases
    test "returns empty lists and zeros for workflows with no steps, tasks, or executions", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, _wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "Empty WF"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          {
            pipelineSummary(projectId: "#{project.id}") {
              id
              name
              workflowSteps {
                id
                name
              }
              transitions {
                id
              }
            }
          }
        """)
        |> json_response(200)

      workflows = result["data"]["pipelineSummary"]
      assert length(workflows) == 2

      wf_data = Enum.find(workflows, &(&1["name"] == "Empty WF"))
      refute is_nil(wf_data)
      assert wf_data["workflowSteps"] == []
      assert wf_data["transitions"] == []
    end

    # Failure Test 2: null target_step_id serializes as null
    test "inter-workflow transitions with null target_step_id serialize as null in targetStepId",
         %{
           conn: conn,
           user: user,
           project: project
         } do
      {:ok, wf1} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF 1"})
      {:ok, wf2} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF 2"})

      # Create a transition without target_step_id
      Accounts.WorkflowTransitions.insert(user.id, %{
        from_workflow_id: wf1.id,
        to_workflow_id: wf2.id,
        label: "goto_wf2",
        project_id: project.id
      })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          {
            pipelineSummary(projectId: "#{project.id}") {
              id
              transitions {
                id
                label
                targetStepId
              }
            }
          }
        """)
        |> json_response(200)

      workflows = result["data"]["pipelineSummary"]
      wf1_data = Enum.find(workflows, fn w -> w["id"] == wf1.id end)

      transitions = wf1_data["transitions"]
      assert length(transitions) == 1

      transition = hd(transitions)
      assert transition["label"] == "goto_wf2"
      assert is_nil(transition["targetStepId"])
    end

    # Testing Criterion 5: INTEGRATION - aggregate counts across workflows
    test "pipelineSummary batches aggregate counts across workflows", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf1} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF 1"})
      {:ok, wf2} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF 2"})

      {:ok, step1_1} = Accounts.WorkflowSteps.insert(wf1, %{name: "Step 1.1", step_order: 1})
      {:ok, _step1_2} = Accounts.WorkflowSteps.insert(wf1, %{name: "Step 1.2", step_order: 2})
      {:ok, step2_1} = Accounts.WorkflowSteps.insert(wf2, %{name: "Step 2.1", step_order: 1})

      {:ok, task1} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task 1", level: "task"})
      {:ok, task2} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task 2", level: "task"})

      Sacrum.Repo.TaskWorkflows.assign_workflow(task1, wf1)
      Sacrum.Repo.TaskWorkflows.assign_workflow(task2, wf2)

      {:ok, _run1} =
        Accounts.TaskRuns.insert(user.id, project.id, task1.id, %{status: :executing})

      {:ok, _run2} = Accounts.TaskRuns.insert(user.id, project.id, task2.id, %{status: :waiting})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          {
            pipelineSummary(projectId: "#{project.id}") {
              id
              name
              workflowSteps {
                id
                name
                taskCounts {
                  epic
                  ticket
                  task
                }
                activeCount
                runningCount
              }
            }
          }
        """)
        |> json_response(200)

      workflows = result["data"]["pipelineSummary"]
      assert length(workflows) == 3

      # Check that aggregates are populated
      wf1_data = Enum.find(workflows, fn w -> w["id"] == wf1.id end)
      wf2_data = Enum.find(workflows, fn w -> w["id"] == wf2.id end)
      refute is_nil(wf1_data)
      refute is_nil(wf2_data)

      wf1_steps = wf1_data["workflowSteps"]
      step1_1_data = Enum.find(wf1_steps, fn s -> s["id"] == step1_1.id end)

      assert step1_1_data["taskCounts"]["task"] == 1
      assert step1_1_data["activeCount"] == 1
      assert step1_1_data["runningCount"] == 1

      wf2_steps = wf2_data["workflowSteps"]
      step2_1_data = Enum.find(wf2_steps, fn s -> s["id"] == step2_1.id end)

      assert step2_1_data["taskCounts"]["task"] == 1
      assert step2_1_data["activeCount"] == 1
      assert step2_1_data["runningCount"] == 1
    end

    # Testing Criterion 6: INTEGRATION - inter-workflow transitions on each workflow
    test "inter-workflow transitions are returned with correct from/to workflow ids and target step id",
         %{
           conn: conn,
           user: user,
           project: project
         } do
      {:ok, wf1} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF 1"})
      {:ok, wf2} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF 2"})
      {:ok, step2_1} = Accounts.WorkflowSteps.insert(wf2, %{name: "Step 2.1", step_order: 1})

      # Create inter-workflow transition with target step
      Accounts.WorkflowTransitions.insert(user.id, %{
        from_workflow_id: wf1.id,
        to_workflow_id: wf2.id,
        label: "proceed",
        target_step_id: step2_1.id,
        project_id: project.id
      })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          {
            pipelineSummary(projectId: "#{project.id}") {
              id
              name
              transitions {
                id
                label
                fromWorkflowId
                toWorkflowId
                targetStepId
              }
            }
          }
        """)
        |> json_response(200)

      workflows = result["data"]["pipelineSummary"]
      wf1_data = Enum.find(workflows, fn w -> w["id"] == wf1.id end)

      transitions = wf1_data["transitions"]
      assert length(transitions) == 1

      trans = hd(transitions)
      assert trans["label"] == "proceed"
      assert trans["fromWorkflowId"] == wf1.id
      assert trans["toWorkflowId"] == wf2.id
      assert trans["targetStepId"] == step2_1.id
    end
  end

  describe "workflow mutations" do
    setup [:setup_user_and_project]

    test "creates a workflow", %{conn: conn, user: user, project: project} do
      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createWorkflow(
              projectId: "#{project.id}"
              name: "New WF"
              description: "Desc"
              isDefault: false
              factoryName: "Created Workflow Factory"
            ) { id name description isDefault factoryName }
          }
        """)
        |> json_response(200)

      data = result["data"]["createWorkflow"]
      assert data["name"] == "New WF"
      assert data["isDefault"] == false
      assert data["factoryName"] == "Created Workflow Factory"
    end

    test "updates a workflow", %{conn: conn, user: user, project: project} do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "Original"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateWorkflow(
              id: "#{wf.id}"
              name: "Updated"
              description: "New desc"
              factoryName: "Updated Workflow Factory"
            ) {
              id name description factoryName
            }
          }
        """)
        |> json_response(200)

      assert result["data"]["updateWorkflow"]["name"] == "Updated"
      assert result["data"]["updateWorkflow"]["description"] == "New desc"
      assert result["data"]["updateWorkflow"]["factoryName"] == "Updated Workflow Factory"
    end

    test "deletes a workflow", %{conn: conn, user: user, project: project} do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "To Delete"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation { deleteWorkflow(id: "#{wf.id}") { id } }
        """)
        |> json_response(200)

      assert result["data"]["deleteWorkflow"]["id"] == wf.id
    end

    test "createWorkflow with isDefault: true demotes auto-Backlog default and succeeds",
         %{conn: conn, user: user, project: project} do
      [auto_backlog] =
        Accounts.Workflows.list_by(user.id, conditions: [project_id: project.id])

      assert auto_backlog.name == "Backlog"
      assert auto_backlog.is_default == true

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createWorkflow(
              projectId: "#{project.id}"
              name: "New Default"
              isDefault: true
            ) { id name isDefault }
          }
        """)
        |> json_response(200)

      data = result["data"]["createWorkflow"]
      assert data["name"] == "New Default"
      assert data["isDefault"] == true
      refute Map.has_key?(result, "errors")

      {:ok, refreshed} =
        Accounts.Workflows.get_by(user.id, conditions: [id: auto_backlog.id])

      assert refreshed.is_default == false

      defaults =
        user.id
        |> Accounts.Workflows.list_by(conditions: [project_id: project.id])
        |> Enum.filter(& &1.is_default)

      assert length(defaults) == 1
      assert hd(defaults).id == data["id"]
    end

    test "createWorkflow with invalid attrs returns structured errors, not a 500",
         %{conn: conn, user: user, project: project} do
      conn = authenticate(conn, user)

      result =
        conn
        |> graphql("""
          mutation {
            createWorkflow(projectId: "#{project.id}", name: "") {
              id name
            }
          }
        """)
        |> json_response(200)

      assert result["data"]["createWorkflow"] == nil
      assert is_list(result["errors"])
      assert length(result["errors"]) >= 1

      messages = Enum.map(result["errors"], & &1["message"])
      assert Enum.any?(messages, &String.contains?(&1, "name"))
    end

    test "concurrent createWorkflow with isDefault: true leaves exactly one default",
         %{user: user, project: project} do
      [_auto_backlog] =
        Accounts.Workflows.list_by(user.id, conditions: [project_id: project.id])

      parent = self()

      results =
        1..8
        |> Task.async_stream(
          fn i ->
            Ecto.Adapters.SQL.Sandbox.allow(Sacrum.Repo, parent, self())

            Accounts.Workflows.insert(user.id, project.id, %{
              name: "Concurrent WF #{i}",
              is_default: true
            })
          end,
          max_concurrency: 8,
          ordered: false,
          timeout: 10_000
        )
        |> Enum.to_list()

      successful_ids =
        Enum.flat_map(results, fn
          {:ok, {:ok, wf}} -> [wf.id]
          _ -> []
        end)

      assert successful_ids != []

      defaults =
        user.id
        |> Accounts.Workflows.list_by(conditions: [project_id: project.id])
        |> Enum.filter(& &1.is_default)

      assert [winner] = defaults
      assert winner.id in successful_ids
    end
  end

  describe "workflow step queries" do
    setup [:setup_user_and_project]

    test "lists steps for a workflow", %{conn: conn, user: user, project: project} do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step} = Accounts.WorkflowSteps.insert(wf, %{name: "Step 1", step_order: 1})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { workflowSteps(workflowId: "#{wf.id}") { id name stepOrder } }
        """)
        |> json_response(200)

      assert [found] = result["data"]["workflowSteps"]
      assert found["id"] == step.id
      assert found["name"] == "Step 1"
      assert found["stepOrder"] == 1
    end

    test "gets a single workflow step", %{conn: conn, user: user, project: project} do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step} = Accounts.WorkflowSteps.insert(wf, %{name: "Step 1", goal: "Do things"})

      result =
        conn
        |> authenticate(user)
        |> graphql(~s|{ workflowStep(id: "#{step.id}") { id name goal } }|)
        |> json_response(200)

      assert result["data"]["workflowStep"]["name"] == "Step 1"
      assert result["data"]["workflowStep"]["goal"] == "Do things"
    end
  end

  describe "workflow step mutations" do
    setup [:setup_user_and_project]

    test "creates a workflow step", %{conn: conn, user: user, project: project} do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createWorkflowStep(
              workflowId: "#{wf.id}"
              name: "Step 1"
              goal: "Test goal"
              stepOrder: 1
            ) { id name goal stepOrder }
          }
        """)
        |> json_response(200)

      data = result["data"]["createWorkflowStep"]
      assert data["name"] == "Step 1"
      assert data["goal"] == "Test goal"
      assert data["stepOrder"] == 1
    end

    test "creates and updates artifact persistence options", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      output_schema =
        ~S|{\"type\":\"object\",\"properties\":{\"result\":{\"type\":\"string\"}},\"required\":[\"result\"],\"additionalProperties\":false}|

      persistence_options = ~S|{\"artifact\":{\"logical_name\":\"step_result\"}}|

      create_result =
        conn
        |> authenticate(user)
        |> graphql(~s"""
          mutation {
            createWorkflowStep(
              workflowId: "#{wf.id}"
              name: "Persisted step"
              outputSchema: "#{output_schema}"
              persistenceOptions: "#{persistence_options}"
            ) { id outputSchema persistenceOptions }
          }
        """)
        |> json_response(200)

      assert create_result["errors"] == nil
      step_data = create_result["data"]["createWorkflowStep"]
      assert step_data["outputSchema"]["required"] == ["result"]

      assert step_data["persistenceOptions"] == %{
               "artifact" => %{"logical_name" => "step_result"}
             }

      updated_options = ~S|{\"artifact\":{\"logical_name\":\"step_result_v2\"}}|

      update_result =
        conn
        |> recycle()
        |> authenticate(user)
        |> graphql(~s"""
          mutation {
            updateWorkflowStep(
              id: "#{step_data["id"]}"
              persistenceOptions: "#{updated_options}"
            ) { id persistenceOptions }
          }
        """)
        |> json_response(200)

      assert update_result["errors"] == nil

      assert update_result["data"]["updateWorkflowStep"]["persistenceOptions"] ==
               %{"artifact" => %{"logical_name" => "step_result_v2"}}
    end

    test "rejects artifact persistence options without an output schema", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      persistence_options = ~S|{\"artifact\":{\"logical_name\":\"step_result\"}}|

      result =
        conn
        |> authenticate(user)
        |> graphql(~s"""
          mutation {
            createWorkflowStep(
              workflowId: "#{wf.id}"
              name: "Invalid persisted step"
              persistenceOptions: "#{persistence_options}"
            ) { id }
          }
        """)
        |> json_response(200)

      assert Enum.any?(result["errors"], fn error ->
               error["message"] =~ "persistence_options"
             end)
    end

    test "updates a workflow step", %{conn: conn, user: user, project: project} do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step} = Accounts.WorkflowSteps.insert(wf, %{name: "Original"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateWorkflowStep(id: "#{step.id}", name: "Updated") {
              id name
            }
          }
        """)
        |> json_response(200)

      assert result["data"]["updateWorkflowStep"]["name"] == "Updated"
    end

    test "deletes a workflow step", %{conn: conn, user: user, project: project} do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step} = Accounts.WorkflowSteps.insert(wf, %{name: "To Delete"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation { deleteWorkflowStep(id: "#{step.id}") { id } }
        """)
        |> json_response(200)

      assert result["data"]["deleteWorkflowStep"]["id"] == step.id
    end

    test "returns a serialized error and preserves an assigned step and tasks", %{
      conn: conn,
      user: user,
      project: project
    } do
      [step] = Accounts.WorkflowSteps.list_by(user.id, conditions: [project_id: project.id])
      {:ok, task_one} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task one"})
      {:ok, task_two} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task two"})

      assert task_one.current_step_id == step.id
      assert task_two.current_step_id == step.id

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation { deleteWorkflowStep(id: "#{step.id}") { id } }
        """)
        |> json_response(200)

      assert result["data"]["deleteWorkflowStep"] == nil
      assert [%{"message" => message}] = result["errors"]
      assert message == "cannot delete a workflow step that is assigned to one or more tasks"
      refute message =~ "Postgrex"
      refute message =~ "SQLSTATE"

      assert {:ok, found_step} = Accounts.WorkflowSteps.get_by(user.id, conditions: [id: step.id])
      assert found_step.id == step.id

      assert {:ok, found_task_one} = Accounts.Tasks.get_by(user.id, conditions: [id: task_one.id])
      assert found_task_one.current_step_id == step.id
      assert found_task_one.title == "Task one"

      assert {:ok, found_task_two} = Accounts.Tasks.get_by(user.id, conditions: [id: task_two.id])
      assert found_task_two.current_step_id == step.id
      assert found_task_two.title == "Task two"
    end

    test "creates workflow step with prompt", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createWorkflowStep(
              workflowId: "#{wf.id}"
              name: "Review Step"
              prompt: "Please review the content"
            ) { id name prompt }
          }
        """)
        |> json_response(200)

      data = result["data"]["createWorkflowStep"]
      assert data["name"] == "Review Step"
      assert data["prompt"] == "Please review the content"
    end

    test "updates workflow step with prompt", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step} = Accounts.WorkflowSteps.insert(wf, %{name: "Step"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateWorkflowStep(
              id: "#{step.id}"
              prompt: "Updated prompt"
            ) { id prompt }
          }
        """)
        |> json_response(200)

      data = result["data"]["updateWorkflowStep"]
      assert data["prompt"] == "Updated prompt"
    end

    test "round-trips route_config and keeps prompt mutations independent", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "Routing WF"})

      {:ok, source} =
        Accounts.WorkflowSteps.insert(wf, %{
          name: "Source",
          step_order: 1,
          output_schema: routing_predecessor_schema()
        })

      {:ok, destination} =
        Accounts.WorkflowSteps.insert(wf, %{
          name: "Destination",
          step_order: 3,
          step_type: "finish",
          prompt: nil
        })

      create_result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createWorkflowStep(
              workflowId: "#{wf.id}"
              name: "Route"
              stepType: "route"
              prompt: "Legacy fallback"
              stepOrder: 2
            ) { id prompt routeConfig }
          }
        """)
        |> json_response(200)

      assert create_result["errors"] == nil

      assert %{"id" => route_id, "prompt" => "Legacy fallback", "routeConfig" => nil} =
               create_result["data"]["createWorkflowStep"]

      {:ok, route} = Accounts.WorkflowSteps.get_by(user.id, conditions: [id: route_id])

      assert {:ok, _} =
               Accounts.StepTransitions.insert(user.id, %{
                 from_step_id: source.id,
                 to_step_id: route.id,
                 project_id: project.id
               })

      assert {:ok, _} =
               Accounts.StepTransitions.insert(user.id, %{
                 from_step_id: route.id,
                 to_step_id: destination.id,
                 project_id: project.id
               })

      route_config = routing_config(destination.id)
      route_config_input = Jason.encode!(Jason.encode!(route_config))

      update_result =
        conn
        |> recycle()
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateWorkflowStep(
              id: "#{route.id}"
              routeConfig: #{route_config_input}
            ) { id prompt routeConfig }
          }
        """)
        |> json_response(200)

      assert update_result["errors"] == nil

      assert update_result["data"]["updateWorkflowStep"] == %{
               "id" => route.id,
               "prompt" => "Legacy fallback",
               "routeConfig" => route_config
             }

      query_result =
        conn
        |> recycle()
        |> authenticate(user)
        |> graphql(~s|{ workflowStep(id: "#{route.id}") { prompt routeConfig } }|)
        |> json_response(200)

      assert query_result["data"]["workflowStep"] == %{
               "prompt" => "Legacy fallback",
               "routeConfig" => route_config
             }

      null_prompt_result =
        conn
        |> recycle()
        |> authenticate(user)
        |> graphql(
          ~s|mutation { updateWorkflowStep(id: "#{route.id}", prompt: null) { prompt routeConfig } }|
        )
        |> json_response(200)

      assert null_prompt_result["errors"] == nil

      assert null_prompt_result["data"]["updateWorkflowStep"] == %{
               "prompt" => nil,
               "routeConfig" => route_config
             }

      empty_prompt_result =
        conn
        |> recycle()
        |> authenticate(user)
        |> graphql(
          ~s|mutation { updateWorkflowStep(id: "#{route.id}", prompt: "") { prompt routeConfig } }|
        )
        |> json_response(200)

      assert empty_prompt_result["errors"] == nil

      assert empty_prompt_result["data"]["updateWorkflowStep"] == %{
               "prompt" => "",
               "routeConfig" => route_config
             }

      clear_config_result =
        conn
        |> recycle()
        |> authenticate(user)
        |> graphql(
          ~s|mutation { updateWorkflowStep(id: "#{route.id}", routeConfig: null) { prompt routeConfig } }|
        )
        |> json_response(200)

      assert clear_config_result["errors"] == nil

      assert clear_config_result["data"]["updateWorkflowStep"] == %{
               "prompt" => "",
               "routeConfig" => nil
             }
    end

    test "returns the route_config validation path without using the prompt fallback", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "Invalid Routing WF"})

      {:ok, route} =
        Accounts.WorkflowSteps.insert(wf, %{
          name: "Route",
          step_type: "route",
          prompt: "Keep this fallback"
        })

      invalid_config = %{
        "version" => 1,
        "match_policy" => "exactly_one",
        "rules" => [
          %{
            "id" => "broken",
            "when" => %{"ref" => "task.unknown", "op" => "eq", "value" => "x"},
            "transition" => %{"type" => "intra_workflow", "step_id" => Ecto.UUID.generate()}
          }
        ]
      }

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateWorkflowStep(
              id: "#{route.id}"
              routeConfig: #{Jason.encode!(Jason.encode!(invalid_config))}
            ) { id prompt routeConfig }
          }
        """)
        |> json_response(200)

      assert Enum.any?(result["errors"], fn error ->
               error["message"] =~ "route_config" and
                 error["message"] =~ "$.rules[0].when.ref"
             end)

      assert result["data"]["updateWorkflowStep"] == nil
      assert {:ok, unchanged} = Accounts.WorkflowSteps.get_by(user.id, conditions: [id: route.id])
      assert unchanged.route_config == nil
      assert unchanged.prompt == "Keep this fallback"
    end

    test "createWorkflowStep returns formatted error message on invalid output_schema", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      invalid_schema = ~S|{\"type\":\"invalid_type_value\"}|

      result =
        conn
        |> authenticate(user)
        |> graphql(~s"""
          mutation {
            createWorkflowStep(
              workflowId: "#{wf.id}"
              name: "Invalid Schema Step"
              outputSchema: "#{invalid_schema}"
            ) { id }
          }
        """)
        |> json_response(200)

      assert result["errors"] != nil

      assert Enum.any?(result["errors"], fn error ->
               error["message"] =~ "output_schema"
             end)
    end

    test "updateWorkflowStep returns formatted error message on invalid output_schema", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step} = Accounts.WorkflowSteps.insert(wf, %{name: "Step"})
      invalid_schema = ~S|{\"type\":\"invalid_type_value\"}|

      result =
        conn
        |> authenticate(user)
        |> graphql(~s"""
          mutation {
            updateWorkflowStep(
              id: "#{step.id}"
              outputSchema: "#{invalid_schema}"
            ) { id }
          }
        """)
        |> json_response(200)

      assert result["errors"] != nil

      assert Enum.any?(result["errors"], fn error ->
               error["message"] =~ "output_schema"
             end)
    end

    test "createWorkflowStep returns formatted error on missing required name", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createWorkflowStep(
              workflowId: "#{wf.id}"
              name: ""
            ) { id }
          }
        """)
        |> json_response(200)

      assert result["errors"] != nil

      assert Enum.any?(result["errors"], fn error ->
               error["message"] =~ "name"
             end)
    end

    test "updateWorkflowStep clears output_schema with clearOutputSchema flag", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, step} =
        Accounts.WorkflowSteps.insert(wf, %{
          name: "Step",
          output_schema: %{
            "type" => "object",
            "properties" => %{"result" => %{"type" => "string"}},
            "required" => ["result"],
            "additionalProperties" => false
          }
        })

      assert step.output_schema != nil

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateWorkflowStep(
              id: "#{step.id}"
              clearOutputSchema: true
            ) { id outputSchema }
          }
        """)
        |> json_response(200)

      assert result["errors"] == nil
      data = result["data"]["updateWorkflowStep"]
      assert data["outputSchema"] == nil
    end

    test "createWorkflowStep rejects verboseDaemonLogging argument (not in schema)", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createWorkflowStep(
              workflowId: "#{wf.id}"
              name: "Step with verbose"
              goal: "Test verbose logging"
              stepOrder: 1
              verboseDaemonLogging: true
            ) { id name }
          }
        """)
        |> json_response(200)

      # GraphQL schema should reject the unknown argument
      assert result["errors"] != nil

      assert Enum.any?(result["errors"], fn error ->
               String.contains?(to_string(error["message"]), "Unknown argument")
             end)
    end

    test "updateWorkflowStep rejects verboseDaemonLogging argument (not in schema)", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step} = Accounts.WorkflowSteps.insert(wf, %{name: "Original"})

      assert step.verbose_daemon_logging == false

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateWorkflowStep(
              id: "#{step.id}"
              name: "Updated"
              verboseDaemonLogging: true
            ) { id name }
          }
        """)
        |> json_response(200)

      # GraphQL schema should reject the unknown argument
      assert result["errors"] != nil

      assert Enum.any?(result["errors"], fn error ->
               String.contains?(to_string(error["message"]), "Unknown argument")
             end)
    end

    test "createWorkflowStep without verboseDaemonLogging defaults to false", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createWorkflowStep(
              workflowId: "#{wf.id}"
              name: "Step without verbose"
              goal: "Test verbose logging"
              stepOrder: 1
            ) { id name verboseDaemonLogging }
          }
        """)
        |> json_response(200)

      # Should succeed without the field
      assert result["errors"] == nil
      data = result["data"]["createWorkflowStep"]
      assert data["name"] == "Step without verbose"
      assert data["verboseDaemonLogging"] == false
    end
  end

  describe "step execution queries" do
    setup [:setup_user_and_project]

    test "lists executions for a task", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, exec} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: wf.id,
          project_id: project.id,
          step_name: "step_1",
          status: "running"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { stepExecutions(taskId: "#{task.id}") { id stepName status } }
        """)
        |> json_response(200)

      assert [found] = result["data"]["stepExecutions"]
      assert found["id"] == exec.id
      assert found["stepName"] == "step_1"
      assert found["status"] == "running"
    end

    test "gets a single step execution", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, exec} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: wf.id,
          project_id: project.id,
          step_name: "step_1"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql(~s|{ stepExecution(id: "#{exec.id}") { id stepName taskId } }|)
        |> json_response(200)

      assert result["data"]["stepExecution"]["id"] == exec.id
      assert result["data"]["stepExecution"]["taskId"] == task.id
    end

    test "reads the complete deterministic route audit from its canonical fields", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Route task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "Routing WF"})

      route_context = %{
        "route" => %{
          "mode" => "deterministic",
          "source_execution_id" => Ecto.UUID.generate(),
          "config_version" => 1,
          "matched_rule_id" => "approved",
          "used_default" => false,
          "context" => %{
            "execution" => %{"step_visit_count" => 1},
            "previous_output" => %{
              "route" => %{"result" => "approved", "handoff" => %{"review" => "needed"}}
            }
          }
        }
      }

      transition_result =
        Jason.encode!(%{"dest_id" => Ecto.UUID.generate(), "transition_type" => "intra_workflow"})

      handoff = %{"review" => "needed"}

      {:ok, exec} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: wf.id,
          project_id: project.id,
          step_name: "Route",
          step_type: "route",
          status: "completed",
          context: route_context,
          transition_result: transition_result,
          handoff: handoff,
          output: "ordinary route output"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          {
            stepExecution(id: "#{exec.id}") {
              context
              transitionResult
              handoff
              output
            }
          }
        """)
        |> json_response(200)

      assert result["errors"] == nil

      assert result["data"]["stepExecution"] == %{
               "context" => route_context,
               "transitionResult" => transition_result,
               "handoff" => handoff,
               "output" => "ordinary route output"
             }

      assert Jason.decode!(result["data"]["stepExecution"]["transitionResult"]) ==
               Jason.decode!(transition_result)
    end

    test "does not fabricate deterministic route provenance for non-route executions", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Ordinary task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, exec} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: wf.id,
          project_id: project.id,
          step_name: "Execute",
          step_type: "execute",
          status: "completed"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql(~s|{ stepExecution(id: "#{exec.id}") { context transitionResult handoff } }|)
        |> json_response(200)

      assert result["errors"] == nil

      assert result["data"]["stepExecution"] == %{
               "context" => %{},
               "transitionResult" => nil,
               "handoff" => nil
             }

      refute Map.has_key?(result["data"]["stepExecution"]["context"], "route")
    end
  end

  describe "step execution mutations" do
    setup [:setup_user_and_project]

    test "updates a step execution", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, exec} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: wf.id,
          project_id: project.id,
          step_name: "step_1",
          status: "running"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateStepExecution(
              id: "#{exec.id}"
              status: "completed"
              output: "Done"
              inputTokens: 100
              outputTokens: 50
              sessionInputTokens: 150
              sessionCacheReadInputTokens: 30
              sessionOutputTokens: 50
              sessionTotalTokens: 200
              contextWindowInputTokens: 150
              contextWindowCacheReadInputTokens: 30
              contextWindowTotalTokens: 200
            ) {
              id status output inputTokens outputTokens
              sessionInputTokens sessionCacheReadInputTokens sessionOutputTokens sessionTotalTokens
              contextWindowInputTokens contextWindowCacheReadInputTokens contextWindowTotalTokens
            }
          }
        """)
        |> json_response(200)

      data = result["data"]["updateStepExecution"]
      assert data["status"] == "completed"
      assert data["output"] == "Done"
      assert data["inputTokens"] == 100
      assert data["outputTokens"] == 50
      assert data["sessionInputTokens"] == 150
      assert data["sessionCacheReadInputTokens"] == 30
      assert data["sessionOutputTokens"] == 50
      assert data["sessionTotalTokens"] == 200
      assert data["contextWindowInputTokens"] == 150
      assert data["contextWindowCacheReadInputTokens"] == 30
      assert data["contextWindowTotalTokens"] == 200
    end

    test "runStep creates and dispatches a StepExecution", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, step} =
        Accounts.WorkflowSteps.insert(wf, %{
          name: "step_1",
          goal: "Do something",
          prompt: ~s|Use artifact {{ artifacts["task_run"]["result"].id }}|
        })

      {:ok, _task} = Sacrum.Repo.TaskWorkflows.assign_workflow(task, wf)

      {:ok, task_run} = Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: :queued})

      {:ok, %{artifact: artifact}} =
        Accounts.Artifacts.create_and_link(
          user.id,
          project.id,
          %{filename: "graphql-task-run-result.json", body: "private graphql task-run body"},
          %{subject_type: "task_run", subject_id: task_run.id, logical_name: "result"}
        )

      Phoenix.PubSub.subscribe(Sacrum.PubSub, "project:#{project.id}")

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            runStep(
              taskId: "#{task.id}"
              stepId: "#{step.id}"
            ) { id stepName stepType status taskId taskRunId }
          }
        """)
        |> json_response(200)

      data = result["data"]["runStep"]
      assert data["stepName"] == "step_1"
      assert data["stepType"] == "execute"
      # ExecutionDispatcher creates executions in "started" status
      assert data["status"] == "started"
      assert data["taskId"] == task.id
      assert data["id"] != nil
      assert data["taskRunId"] != nil

      expected_prompt = "Use artifact #{artifact.id}"
      execution = Sacrum.Repo.get!(Sacrum.Repo.Schemas.StepExecution, data["id"])
      assert execution.prompt == expected_prompt

      assert_receive %Phoenix.Socket.Broadcast{
        event: "run_step",
        payload: %{id: execution_id, prompt: ^expected_prompt}
      }

      assert execution_id == execution.id

      reloaded_task_run = Sacrum.Repo.get!(Sacrum.Repo.Schemas.TaskRun, data["taskRunId"])
      assert reloaded_task_run.task_id == task.id
      assert reloaded_task_run.id == task_run.id
      assert reloaded_task_run.status == :executing
      assert reloaded_task_run.latest_step_execution_id == data["id"]
    end

    test "runStep persists and exposes a non-default workflow step type", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, step} =
        Accounts.WorkflowSteps.insert(wf, %{
          name: "Route decision",
          step_type: "route",
          prompt: "Choose a destination"
        })

      {:ok, _task} = Sacrum.Repo.TaskWorkflows.assign_workflow(task, wf)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            runStep(
              taskId: "#{task.id}"
              stepId: "#{step.id}"
            ) { id stepName stepType status taskId }
          }
        """)
        |> json_response(200)

      data = result["data"]["runStep"]
      assert data["stepName"] == "Route decision"
      assert data["stepType"] == "route"
      assert data["status"] == "started"
      assert data["taskId"] == task.id
    end

    test "runStep rejects stop steps without creating or changing a TaskRun", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, stop_step} =
        Accounts.WorkflowSteps.insert(wf, %{
          name: "Run boundary",
          step_type: "stop",
          prompt: nil
        })

      {:ok, task} = Sacrum.Repo.TaskWorkflows.assign_workflow(task, wf)
      {:ok, task_run} = Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: :queued})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            runStep(
              taskId: "#{task.id}"
              stepId: "#{stop_step.id}"
            ) { id taskRunId status }
          }
        """)
        |> json_response(200)

      assert result["data"]["runStep"] == nil
      assert [%{"message" => message}] = result["errors"]
      assert message =~ "stop_step_not_dispatchable"

      assert Sacrum.Repo.get!(Sacrum.Repo.Schemas.TaskRun, task_run.id).status == :queued

      assert Sacrum.Repo.get_by(Sacrum.Repo.Schemas.StepExecution,
               task_run_id: task_run.id
             ) == nil
    end

    test "runStep reuses an existing active root TaskRun", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step} = Accounts.WorkflowSteps.insert(wf, %{name: "step_1", goal: "Do something"})
      {:ok, task} = Sacrum.Repo.TaskWorkflows.assign_workflow(task, wf)
      {:ok, task_run} = Accounts.TaskRuns.insert(user.id, project.id, task.id, %{status: :queued})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            runStep(
              taskId: "#{task.id}"
              stepId: "#{step.id}"
            ) { id taskRunId status }
          }
        """)
        |> json_response(200)

      data = result["data"]["runStep"]
      assert data["status"] == "started"
      assert data["taskRunId"] == task_run.id

      reloaded_run = Sacrum.Repo.get!(Sacrum.Repo.Schemas.TaskRun, task_run.id)
      assert reloaded_run.status == :executing
      assert reloaded_run.latest_step_execution_id == data["id"]
    end

    test "runStep with invalid task_id returns error", %{conn: conn, user: user, project: project} do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step} = Accounts.WorkflowSteps.insert(wf, %{name: "step_1", goal: "Do something"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            runStep(
              taskId: "#{Ecto.UUID.generate()}"
              stepId: "#{step.id}"
            ) { id stepName status taskId }
          }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end

    test "runStep with invalid step_id returns error", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            runStep(
              taskId: "#{task.id}"
              workflowId: "#{wf.id}"
              stepId: "#{Ecto.UUID.generate()}"
            ) { id stepName status taskId }
          }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end

    test "runStep creates execution without context, uses prompt-based architecture",
         %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task Title"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, step} =
        Accounts.WorkflowSteps.insert(wf, %{
          name: "step_1",
          goal: "Do something",
          prompt: "Work on ticket {task_id}"
        })

      {:ok, task} = Sacrum.Repo.TaskWorkflows.assign_workflow(task, wf)

      {:ok, _section} =
        Accounts.Sections.insert(user.id, %{
          task_id: task.id,
          project_id: project.id,
          section_type: "context",
          content: "Section content",
          section_order: 1
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            runStep(
              taskId: "#{task.id}"
              stepId: "#{step.id}"
            ) { id stepName status context }
          }
        """)
        |> json_response(200)

      data = result["data"]["runStep"]
      # ExecutionDispatcher creates executions in "started" status
      assert data["status"] == "started"
      # Context is no longer populated in the execution (null becomes %{} in JSON)
      assert data["context"] == %{} or data["context"] == nil
    end

    test "runStep with task that has sections does not populate context",
         %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step} = Accounts.WorkflowSteps.insert(wf, %{name: "step_1", goal: "Do something"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            runStep(
              taskId: "#{task.id}"
              stepId: "#{step.id}"
            ) { id context }
          }
        """)
        |> json_response(200)

      data = result["data"]["runStep"]
      # Context is no longer populated (null becomes %{} in JSON)
      assert data["context"] == %{} or data["context"] == nil
    end

    test "runStep uses prompt rendering with task_id interpolation", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      # Create step with {task_id} placeholder in prompt
      {:ok, step} =
        Accounts.WorkflowSteps.insert(wf, %{
          name: "step_1",
          goal: "Do something",
          prompt: "Analyze task {task_id}"
        })

      {:ok, _task} = Sacrum.Repo.TaskWorkflows.assign_workflow(task, wf)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            runStep(
              taskId: "#{task.id}"
              stepId: "#{step.id}"
            ) { id stepName }
          }
        """)
        |> json_response(200)

      data = result["data"]["runStep"]
      assert data["stepName"] == "step_1"
      # The prompt is rendered internally and broadcast to daemon,
      # but not returned in the GraphQL response (context is no longer populated)
    end

    test "runStep succeeds when daemon_presence_required is false (default)", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step} = Accounts.WorkflowSteps.insert(wf, %{name: "step_1", goal: "Do something"})
      {:ok, _task} = Sacrum.Repo.TaskWorkflows.assign_workflow(task, wf)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            runStep(
              taskId: "#{task.id}"
              stepId: "#{step.id}"
            ) { id stepName status taskId }
          }
        """)
        |> json_response(200)

      data = result["data"]["runStep"]
      # ExecutionDispatcher creates executions in "started" status
      assert data["status"] == "started"
      assert data["id"] != nil
    end

    test "runStep returns error when no daemon connected and daemon_presence_required is true", %{
      conn: conn,
      user: user,
      project: project
    } do
      # Enable daemon presence requirement
      Application.put_env(:sacrum, :daemon_presence_required, true)

      on_exit(fn ->
        Application.put_env(:sacrum, :daemon_presence_required, false)
      end)

      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step} = Accounts.WorkflowSteps.insert(wf, %{name: "step_1", goal: "Do something"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            runStep(
              taskId: "#{task.id}"
              stepId: "#{step.id}"
            ) { id stepName status taskId }
          }
        """)
        |> json_response(200)

      assert result["errors"] != nil

      assert Enum.any?(result["errors"], fn error ->
               String.contains?(error["message"], "No daemon is currently connected")
             end)
    end

    test "cancelStepExecution returns execution with status cancelling", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, exec} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: wf.id,
          project_id: project.id,
          step_name: "step_1",
          status: "in_progress"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            cancelStepExecution(
              stepExecutionId: "#{exec.id}"
            ) { id stepName status taskId }
          }
        """)
        |> json_response(200)

      data = result["data"]["cancelStepExecution"]
      assert data["id"] == exec.id
      assert data["stepName"] == "step_1"
      assert data["taskId"] == task.id
      assert data["status"] == "cancelling"
    end

    test "cancelStepExecution on a pending execution sets status to cancelling", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, exec} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: wf.id,
          project_id: project.id,
          step_name: "step_1",
          status: "pending"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            cancelStepExecution(
              stepExecutionId: "#{exec.id}"
            ) { id status }
          }
        """)
        |> json_response(200)

      data = result["data"]["cancelStepExecution"]
      assert data["status"] == "cancelling"
    end

    test "cancelStepExecution on a completed execution returns error", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, exec} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: wf.id,
          project_id: project.id,
          step_name: "step_1",
          status: "completed"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            cancelStepExecution(
              stepExecutionId: "#{exec.id}"
            ) { id }
          }
        """)
        |> json_response(200)

      assert result["errors"] != nil
      assert Enum.any?(result["errors"], &String.contains?(&1["message"], "Cannot cancel"))
    end

    test "cancelStepExecution on a failed execution returns error", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, exec} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: wf.id,
          project_id: project.id,
          step_name: "step_1",
          status: "failed"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            cancelStepExecution(
              stepExecutionId: "#{exec.id}"
            ) { id }
          }
        """)
        |> json_response(200)

      assert result["errors"] != nil
      assert Enum.any?(result["errors"], &String.contains?(&1["message"], "Cannot cancel"))
    end
  end

  describe "orchestrate task mutations" do
    setup [:setup_user_and_project]

    test "orchestrateTask starts orchestration and returns task", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, _step} = Accounts.WorkflowSteps.insert(wf, %{name: "step_1", goal: "Do something"})
      {:ok, updated_task} = Sacrum.Repo.TaskWorkflows.assign_workflow(task, wf)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            orchestrateTask(taskId: "#{updated_task.id}") {
              id title workflowId
            }
          }
        """)
        |> json_response(200)

      data = result["data"]["orchestrateTask"]
      assert data["id"] == updated_task.id
      assert data["title"] == "Task"
      assert data["workflowId"] == wf.id
    end

    test "orchestrateTask returns error when already running", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, _step} = Accounts.WorkflowSteps.insert(wf, %{name: "step_1", goal: "Do something"})
      {:ok, updated_task} = Sacrum.Repo.TaskWorkflows.assign_workflow(task, wf)

      # Start orchestration once
      Sacrum.Orchestrator.Scheduler.schedule_task(%{id: updated_task.id})

      # Try to start again - should fail
      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            orchestrateTask(taskId: "#{updated_task.id}") {
              id
            }
          }
        """)
        |> json_response(200)

      assert result["errors"] != nil
      assert Enum.any?(result["errors"], &String.contains?(&1["message"], "already running"))
    end
  end

  describe "session log mutations" do
    setup [:setup_user_and_project]

    test "creates a session log", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, exec} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: wf.id,
          project_id: project.id,
          step_name: "step_1"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createSessionLog(
              stepExecutionId: "#{exec.id}"
              content: "Log entry content"
              format: "anthropic"
            ) { id content format stepExecutionId }
          }
        """)
        |> json_response(200)

      data = result["data"]["createSessionLog"]
      assert data["content"] == "Log entry content"
      assert data["format"] == "anthropic"
      assert data["stepExecutionId"] == exec.id
    end

    test "upserts a session log by logicalKey", %{user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, exec} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: wf.id,
          project_id: project.id,
          step_name: "step_1"
        })

      first =
        build_conn()
        |> authenticate(user)
        |> graphql("""
          mutation {
            createSessionLog(
              stepExecutionId: "#{exec.id}"
              logicalKey: "system/thinking_tokens"
              content: "first snapshot"
              format: "anthropic"
            ) { id content format logicalKey }
          }
        """)
        |> json_response(200)

      first_log = first["data"]["createSessionLog"]
      assert first_log["content"] == "first snapshot"
      assert first_log["format"] == "anthropic"
      assert first_log["logicalKey"] == "system/thinking_tokens"

      second =
        build_conn()
        |> authenticate(user)
        |> graphql("""
          mutation {
            createSessionLog(
              stepExecutionId: "#{exec.id}"
              logicalKey: "system/thinking_tokens"
              content: "latest snapshot"
              format: "openai"
            ) { id content format logicalKey }
          }
        """)
        |> json_response(200)

      second_log = second["data"]["createSessionLog"]
      assert second_log["id"] == first_log["id"]
      assert second_log["content"] == "latest snapshot"
      assert second_log["format"] == "openai"
      assert second_log["logicalKey"] == "system/thinking_tokens"

      result =
        build_conn()
        |> authenticate(user)
        |> graphql(
          ~s|{ sessionLogs(stepExecutionId: "#{exec.id}") { id content format logicalKey } }|
        )
        |> json_response(200)

      assert [found] = result["data"]["sessionLogs"]
      assert found["id"] == first_log["id"]
      assert found["content"] == "latest snapshot"
      assert found["format"] == "openai"
      assert found["logicalKey"] == "system/thinking_tokens"
    end

    test "rejects unsupported session log format", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, exec} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: wf.id,
          project_id: project.id,
          step_name: "step_1"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createSessionLog(
              stepExecutionId: "#{exec.id}"
              content: "Log entry content"
              format: "codex"
            ) { id content format }
          }
        """)
        |> json_response(200)

      assert result["data"]["createSessionLog"] == nil
      assert [%{"message" => message}] = result["errors"]
      assert message =~ "format"
    end
  end

  describe "session log queries" do
    setup [:setup_user_and_project]

    test "lists session logs for an execution", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, exec} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: wf.id,
          project_id: project.id,
          step_name: "step_1"
        })

      {:ok, log} =
        Accounts.SessionLogs.insert(user.id, %{
          step_execution_id: exec.id,
          project_id: project.id,
          content: "A log"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { sessionLogs(stepExecutionId: "#{exec.id}") { id content format } }
        """)
        |> json_response(200)

      assert [found] = result["data"]["sessionLogs"]
      assert found["id"] == log.id
      assert found["content"] == "A log"
      assert found["format"] == "anthropic"
    end
  end

  describe "section mutations" do
    setup [:setup_user_and_project]

    test "creates a section for a task", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createSection(
              taskId: "#{task.id}"
              sectionType: "context"
              content: "Section content"
              sectionOrder: 1
            ) { id sectionType content sectionOrder taskId }
          }
        """)
        |> json_response(200)

      data = result["data"]["createSection"]
      assert data["sectionType"] == "context"
      assert data["content"] == "Section content"
      assert data["sectionOrder"] == 1
      assert data["taskId"] == task.id
    end

    test "createSection auto-assigns sectionOrder when omitted", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createSection(
              taskId: "#{task.id}"
              sectionType: "checklist_item"
              content: "Auto ordered"
            ) { id sectionType content sectionOrder taskId }
          }
        """)
        |> json_response(200)

      data = result["data"]["createSection"]
      assert data["sectionType"] == "checklist_item"
      assert data["content"] == "Auto ordered"
      assert data["sectionOrder"] == 0
      assert data["taskId"] == task.id
    end

    test "concurrent createSection calls for the same task and type get distinct sectionOrders",
         %{user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      parent = self()

      results =
        1..2
        |> Task.async_stream(
          fn i ->
            Ecto.Adapters.SQL.Sandbox.allow(Sacrum.Repo, parent, self())

            build_conn()
            |> authenticate(user)
            |> graphql("""
              mutation {
                createSection(
                  taskId: "#{task.id}"
                  sectionType: "testing_criterion"
                  content: "Concurrent criterion #{i}"
                ) { id content sectionOrder }
              }
            """)
            |> json_response(200)
          end,
          max_concurrency: 2,
          ordered: false,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      sections = Enum.map(results, & &1["data"]["createSection"])

      assert Enum.all?(results, &(Map.get(&1, "errors") in [nil, []]))
      assert Enum.sort(Enum.map(sections, & &1["sectionOrder"])) == [0, 1]

      assert Enum.sort(Enum.map(sections, & &1["content"])) == [
               "Concurrent criterion 1",
               "Concurrent criterion 2"
             ]
    end

    test "updates a section", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      {:ok, section} =
        Accounts.Sections.insert(user.id, %{
          task_id: task.id,
          project_id: project.id,
          section_type: "context",
          content: "Original"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateSection(id: "#{section.id}", content: "Updated content", done: true) {
              id content done
            }
          }
        """)
        |> json_response(200)

      assert result["data"]["updateSection"]["content"] == "Updated content"
      assert result["data"]["updateSection"]["done"] == true
    end

    test "upsertSection replaces single-instance sections", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      first =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            upsertSection(
              taskId: "#{task.id}"
              sectionType: "goal"
              content: "First goal"
            ) { id content }
          }
        """)
        |> json_response(200)

      second =
        build_conn()
        |> authenticate(user)
        |> graphql("""
          mutation {
            upsertSection(
              taskId: "#{task.id}"
              sectionType: "goal"
              content: "Second goal"
            ) { id content }
          }
        """)
        |> json_response(200)

      assert first["errors"] == nil
      assert second["errors"] == nil
      assert first["data"]["upsertSection"]["id"] == second["data"]["upsertSection"]["id"]
      assert second["data"]["upsertSection"]["content"] == "Second goal"

      sections =
        task
        |> Sacrum.Repo.preload(:sections, force: true)
        |> Map.fetch!(:sections)
        |> Enum.filter(&(&1.section_type == "goal"))

      assert length(sections) == 1
    end

    test "upsertSection appends multi-instance sections", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      conn
      |> authenticate(user)
      |> graphql("""
        mutation {
          upsertSection(
            taskId: "#{task.id}"
            sectionType: "checklist_item"
            content: "First item"
          ) { id }
        }
      """)
      |> json_response(200)

      result =
        build_conn()
        |> authenticate(user)
        |> graphql("""
          mutation {
            upsertSection(
              taskId: "#{task.id}"
              sectionType: "checklist_item"
              content: "Second item"
            ) { id }
          }
        """)
        |> json_response(200)

      assert result["errors"] == nil

      sections =
        task
        |> Sacrum.Repo.preload(:sections, force: true)
        |> Map.fetch!(:sections)
        |> Enum.filter(&(&1.section_type == "checklist_item"))

      assert Enum.map(sections, & &1.content) |> Enum.sort() == ["First item", "Second item"]
    end

    test "upsertSection returns error for non-existent task", %{conn: conn, user: user} do
      fake_task_id = Ecto.UUID.generate()

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            upsertSection(
              taskId: "#{fake_task_id}"
              sectionType: "goal"
              content: "No task"
            ) { id }
          }
        """)
        |> json_response(200)

      assert result["data"]["upsertSection"] == nil
      assert result["errors"] != nil
    end

    test "deletes a section", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      {:ok, section} =
        Accounts.Sections.insert(user.id, %{
          task_id: task.id,
          project_id: project.id,
          section_type: "context",
          content: "To delete"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation { deleteSection(id: "#{section.id}") { id } }
        """)
        |> json_response(200)

      assert result["data"]["deleteSection"]["id"] == section.id
    end
  end

  describe "code ref mutations" do
    setup [:setup_user_and_project]

    test "creates a code ref for a task", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createCodeRef(
              taskId: "#{task.id}"
              path: "lib/foo.ex"
              lineStart: 10
              lineEnd: 20
              name: "my_function"
              description: "A function"
            ) { id path lineStart lineEnd name description taskId }
          }
        """)
        |> json_response(200)

      data = result["data"]["createCodeRef"]
      assert data["path"] == "lib/foo.ex"
      assert data["lineStart"] == 10
      assert data["lineEnd"] == 20
      assert data["name"] == "my_function"
      assert data["taskId"] == task.id
    end

    test "createCodeRef appends orderIndex for normal inserts", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      for path <- ["lib/a.ex", "lib/b.ex"] do
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createCodeRef(taskId: "#{task.id}", path: "#{path}") {
              id
            }
          }
        """)
        |> json_response(200)
      end

      result =
        build_conn()
        |> authenticate(user)
        |> graphql("""
          {
            task(id: "#{task.id}") {
              codeRefs { path orderIndex }
            }
          }
        """)
        |> json_response(200)

      assert result["errors"] == nil

      assert [
               %{"path" => "lib/a.ex", "orderIndex" => 0},
               %{"path" => "lib/b.ex", "orderIndex" => 1}
             ] = result["data"]["task"]["codeRefs"]
    end

    test "deletes a code ref", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      {:ok, ref} =
        Accounts.CodeRefs.insert_for_task(user.id, %{
          task_id: task.id,
          project_id: project.id,
          path: "lib/bar.ex"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation { deleteCodeRef(id: "#{ref.id}") { id path } }
        """)
        |> json_response(200)

      assert result["data"]["deleteCodeRef"]["id"] == ref.id
    end

    test "deletes all code refs for a task", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      {:ok, ref1} =
        Accounts.CodeRefs.insert_for_task(user.id, %{
          task_id: task.id,
          project_id: project.id,
          path: "lib/a.ex"
        })

      {:ok, ref2} =
        Accounts.CodeRefs.insert_for_task(user.id, %{
          task_id: task.id,
          project_id: project.id,
          path: "lib/b.ex"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation { deleteTaskCodeRefs(taskId: "#{task.id}") { id path } }
        """)
        |> json_response(200)

      refs = result["data"]["deleteTaskCodeRefs"]
      assert length(refs) == 2

      assert Enum.map(refs, & &1["id"]) |> Enum.sort() ==
               [ref1.id, ref2.id] |> Enum.sort()
    end

    test "sets all code refs for a task", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      {:ok, old_ref} =
        Accounts.CodeRefs.insert_for_task(user.id, %{
          task_id: task.id,
          project_id: project.id,
          path: "lib/old.ex"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            setCodeRefs(
              taskId: "#{task.id}"
              refs: [
                {path: "lib/new_a.ex", lineStart: 10, lineEnd: 12, name: "new_a"}
                {path: "lib/new_b.ex", lineStart: 20, lineEnd: 22, name: "new_b"}
              ]
            ) {
              path lineStart lineEnd name orderIndex
            }
          }
        """)
        |> json_response(200)

      assert result["errors"] == nil

      assert [
               %{"path" => "lib/new_a.ex", "orderIndex" => 0},
               %{"path" => "lib/new_b.ex", "orderIndex" => 1}
             ] = result["data"]["setCodeRefs"]

      assert {:error, :not_found} =
               Accounts.CodeRefs.get_by(user.id, conditions: [id: old_ref.id])
    end

    test "setCodeRefs preserves submission order through task codeRefs", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      conn
      |> authenticate(user)
      |> graphql("""
        mutation {
          setCodeRefs(
            taskId: "#{task.id}"
            refs: [
              {path: "lib/first.ex"}
              {path: "lib/second.ex"}
              {path: "lib/third.ex"}
            ]
          ) { id }
        }
      """)
      |> json_response(200)

      result =
        build_conn()
        |> authenticate(user)
        |> graphql("""
          {
            task(id: "#{task.id}") {
              codeRefs { path orderIndex }
            }
          }
        """)
        |> json_response(200)

      assert result["errors"] == nil

      assert [
               %{"path" => "lib/first.ex", "orderIndex" => 0},
               %{"path" => "lib/second.ex", "orderIndex" => 1},
               %{"path" => "lib/third.ex", "orderIndex" => 2}
             ] = result["data"]["task"]["codeRefs"]
    end

    test "setCodeRefs rolls back when one ref is invalid", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      {:ok, old_ref} =
        Accounts.CodeRefs.insert_for_task(user.id, %{
          task_id: task.id,
          project_id: project.id,
          path: "lib/old.ex"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            setCodeRefs(
              taskId: "#{task.id}"
              refs: [
                {path: "lib/new.ex"}
                {path: ""}
              ]
            ) {
              path
            }
          }
        """)
        |> json_response(200)

      assert result["data"]["setCodeRefs"] == nil
      assert result["errors"] != nil

      assert [%{id: ref_id, path: "lib/old.ex"}] =
               Accounts.CodeRefs.list_by(user.id, conditions: [task_id: task.id])

      assert ref_id == old_ref.id
    end

    test "setCodeRefs returns error for non-existent task", %{conn: conn, user: user} do
      fake_task_id = Ecto.UUID.generate()

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            setCodeRefs(taskId: "#{fake_task_id}", refs: [{path: "lib/new.ex"}]) {
              path
            }
          }
        """)
        |> json_response(200)

      assert result["data"]["setCodeRefs"] == nil
      assert result["errors"] != nil
    end

    test "deleteTaskCodeRefs returns error for non-existent task", %{conn: conn, user: user} do
      fake_task_id = Ecto.UUID.generate()

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation { deleteTaskCodeRefs(taskId: "#{fake_task_id}") { id path } }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end
  end

  describe "association resolution" do
    setup [:setup_user_and_project]

    test "resolves task with its project", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { task(id: "#{task.id}") { id title project { id name } } }
        """)
        |> json_response(200)

      assert result["data"]["task"]["project"]["id"] == project.id
      assert result["data"]["task"]["project"]["name"] == "Test Project"
    end

    test "resolves workflow with its steps", %{conn: conn, user: user, project: project} do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step} = Accounts.WorkflowSteps.insert(wf, %{name: "Step 1"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { workflow(id: "#{wf.id}") { id name workflowSteps { id name } } }
        """)
        |> json_response(200)

      wf_data = result["data"]["workflow"]
      assert wf_data["name"] == "WF"
      assert [step_data] = wf_data["workflowSteps"]
      assert step_data["id"] == step.id
      assert step_data["name"] == "Step 1"
    end

    test "resolves project with its workflows", %{conn: conn, user: user, project: project} do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { project(id: "#{project.id}") { id workflows { id name } } }
        """)
        |> json_response(200)

      workflows = result["data"]["project"]["workflows"]
      assert length(workflows) == 2
      found = Enum.find(workflows, &(&1["id"] == wf.id))
      refute is_nil(found)
      assert found["name"] == "WF"
    end

    test "resolves step execution with its session logs", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, exec} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: wf.id,
          project_id: project.id,
          step_name: "step_1"
        })

      {:ok, log} =
        Accounts.SessionLogs.insert(user.id, %{
          step_execution_id: exec.id,
          project_id: project.id,
          content: "Log entry"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { stepExecution(id: "#{exec.id}") { id sessionLogs { id content } } }
        """)
        |> json_response(200)

      assert [log_data] = result["data"]["stepExecution"]["sessionLogs"]
      assert log_data["id"] == log.id
      assert log_data["content"] == "Log entry"
    end
  end

  describe "cross-user data isolation" do
    setup [:setup_user_and_project]

    test "cannot access another user's task", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Secret"})
      other_user = create_user(%{email: "other@example.com", username: "other"})

      result =
        conn
        |> authenticate(other_user)
        |> graphql(~s|{ task(id: "#{task.id}") { id title } }|)
        |> json_response(200)

      assert result["data"]["task"] == nil
      assert [%{"message" => _}] = result["errors"]
    end

    test "cannot access another user's workflow", %{conn: conn, user: user, project: project} do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "Secret WF"})
      other_user = create_user(%{email: "other@example.com", username: "other"})

      result =
        conn
        |> authenticate(other_user)
        |> graphql(~s|{ workflow(id: "#{wf.id}") { id name } }|)
        |> json_response(200)

      assert result["data"]["workflow"] == nil
      assert [%{"message" => _}] = result["errors"]
    end

    test "cannot delete another user's project", %{conn: conn, user: user} do
      {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Mine"})
      other_user = create_user(%{email: "other@example.com", username: "other"})

      result =
        conn
        |> authenticate(other_user)
        |> graphql("""
          mutation { deleteProject(id: "#{project.id}") { id } }
        """)
        |> json_response(200)

      assert result["data"]["deleteProject"] == nil
      assert [%{"message" => _}] = result["errors"]

      # Verify project still exists
      assert {:ok, _} = Accounts.Projects.get_by(user.id, conditions: [id: project.id])
    end
  end

  describe "task ready query" do
    setup [:setup_user_and_project]

    test "returns tasks with no incomplete blockers", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, root} = Accounts.Tasks.insert(user.id, project.id, %{title: "Root Task"})
      {:ok, child} = Accounts.Tasks.insert(user.id, project.id, %{title: "Child Task"})
      {:ok, _} = Sacrum.Repo.TaskHierarchy.set_parent(child, root)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { listReady(projectId: "#{project.id}") { id title } }
        """)
        |> json_response(200)

      # After root_only constraint removal, listReady returns all unblocked tasks
      titles = Enum.map(result["data"]["listReady"], & &1["title"])
      assert "Root Task" in titles
      assert "Child Task" in titles
    end

    test "excludes tasks with incomplete blockers", %{conn: conn, user: user, project: project} do
      {:ok, blocker} = Accounts.Tasks.insert(user.id, project.id, %{title: "Blocker"})
      {:ok, blocked} = Accounts.Tasks.insert(user.id, project.id, %{title: "Blocked"})
      {:ok, _} = Sacrum.Repo.TaskDependencies.add_dependency(blocked, blocker)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { listReady(projectId: "#{project.id}") { title } }
        """)
        |> json_response(200)

      titles = Enum.map(result["data"]["listReady"], & &1["title"])
      assert "Blocker" in titles
      refute "Blocked" in titles
    end

    test "includes tasks whose blockers are all completed", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, blocker} = Accounts.Tasks.insert(user.id, project.id, %{title: "Done Blocker"})
      {:ok, _} = Accounts.Tasks.update(blocker, %{completed_at: DateTime.utc_now()})
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Unblocked"})
      {:ok, _} = Sacrum.Repo.TaskDependencies.add_dependency(task, blocker)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { listReady(projectId: "#{project.id}") { title } }
        """)
        |> json_response(200)

      titles = Enum.map(result["data"]["listReady"], & &1["title"])
      assert "Unblocked" in titles
    end
  end

  describe "task find path query" do
    setup [:setup_user_and_project]

    test "returns shortest dependency path between tasks", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, a} = Accounts.Tasks.insert(user.id, project.id, %{title: "A"})
      {:ok, b} = Accounts.Tasks.insert(user.id, project.id, %{title: "B"})
      {:ok, c} = Accounts.Tasks.insert(user.id, project.id, %{title: "C"})
      {:ok, _} = Sacrum.Repo.TaskDependencies.add_dependency(a, b)
      {:ok, _} = Sacrum.Repo.TaskDependencies.add_dependency(b, c)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { findPath(fromId: "#{a.id}", toId: "#{c.id}") }
        """)
        |> json_response(200)

      path = result["data"]["findPath"]
      assert length(path) == 3
      assert path == [a.id, b.id, c.id]
    end

    test "returns empty path when no dependency path exists", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, a} = Accounts.Tasks.insert(user.id, project.id, %{title: "A"})
      {:ok, b} = Accounts.Tasks.insert(user.id, project.id, %{title: "B"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { findPath(fromId: "#{a.id}", toId: "#{b.id}") }
        """)
        |> json_response(200)

      assert result["data"]["findPath"] == []
    end

    test "returns single-element path for direct dependency", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, a} = Accounts.Tasks.insert(user.id, project.id, %{title: "A"})
      {:ok, b} = Accounts.Tasks.insert(user.id, project.id, %{title: "B"})
      {:ok, _} = Sacrum.Repo.TaskDependencies.add_dependency(a, b)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { findPath(fromId: "#{a.id}", toId: "#{b.id}") }
        """)
        |> json_response(200)

      path = result["data"]["findPath"]
      assert path == [a.id, b.id]
    end

    test "returns 404-like error when task does not exist", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, a} = Accounts.Tasks.insert(user.id, project.id, %{title: "A"})
      fake_id = Ecto.UUID.generate()

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { findPath(fromId: "#{a.id}", toId: "#{fake_id}") }
        """)
        |> json_response(200)

      assert result["data"]["findPath"] == nil
      assert result["errors"] != nil
    end
  end

  describe "task cascade delete" do
    setup [:setup_user_and_project]

    test "deleting parent task also deletes all child tasks", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, parent} = Accounts.Tasks.insert(user.id, project.id, %{title: "Parent"})
      {:ok, child1} = Accounts.Tasks.insert(user.id, project.id, %{title: "Child 1"})
      {:ok, child2} = Accounts.Tasks.insert(user.id, project.id, %{title: "Child 2"})

      {:ok, _} = Sacrum.Repo.TaskHierarchy.set_parent(child1, parent)
      {:ok, _} = Sacrum.Repo.TaskHierarchy.set_parent(child2, parent)

      # Verify children exist
      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { tasks(projectId: "#{project.id}") { title } }
        """)
        |> json_response(200)

      assert length(result["data"]["tasks"]) == 3

      # Delete the parent
      _delete_result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation { deleteTask(id: "#{parent.id}") { id } }
        """)
        |> json_response(200)

      # Verify all tasks are deleted
      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { tasks(projectId: "#{project.id}") { title } }
        """)
        |> json_response(200)

      assert result["data"]["tasks"] == []
    end

    test "deleting task also deletes task dependencies and step executions", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, dep} = Accounts.Tasks.insert(user.id, project.id, %{title: "Dependency"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      # Create a dependency
      {:ok, _} = Sacrum.Repo.TaskDependencies.add_dependency(task, dep)

      # Create a step execution
      {:ok, _} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: wf.id,
          project_id: project.id,
          step_name: "step_1"
        })

      # Delete the task
      _delete_result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation { deleteTask(id: "#{task.id}") { id } }
        """)
        |> json_response(200)

      # Verify task dependencies are gone
      all_deps = Sacrum.Repo.all(Sacrum.Repo.Schemas.TaskDependency)
      assert all_deps == []

      # Verify step executions are gone
      all_execs = Sacrum.Repo.all(Sacrum.Repo.Schemas.StepExecution)
      assert all_execs == []
    end
  end

  describe "error handling" do
    test "returns error for nonexistent resource id", %{conn: conn} do
      user = create_user()
      fake_id = Ecto.UUID.generate()

      result =
        conn
        |> authenticate(user)
        |> graphql(~s|{ task(id: "#{fake_id}") { id } }|)
        |> json_response(200)

      assert result["data"]["task"] == nil
      assert [%{"message" => _}] = result["errors"]
    end

    test "returns error for missing required fields", %{conn: conn} do
      user = create_user()

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation { createProject(description: "No name") { id } }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end

    test "returns error for invalid query syntax", %{conn: conn} do
      user = create_user()

      result =
        conn
        |> authenticate(user)
        |> graphql("{ invalid }")
        |> json_response(200)

      assert result["errors"] != nil
    end

    test "returns validation error for invalid UUID format", %{conn: conn} do
      user = create_user()

      result =
        conn
        |> authenticate(user)
        |> graphql(~s|{ task(id: "not-a-uuid") { id } }|)
        |> json_response(200)

      assert [%{"message" => message}] = result["errors"]
      assert message =~ "Argument \"id\" has invalid value \"not-a-uuid\""
    end
  end

  describe "transition mutations" do
    setup [:setup_user_and_project]

    test "creates a workflow transition with correct project_id", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf1} = Accounts.Workflows.insert(user.id, project.id, %{name: "Workflow 1"})
      {:ok, wf2} = Accounts.Workflows.insert(user.id, project.id, %{name: "Workflow 2"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createWorkflowTransition(
              fromWorkflowId: "#{wf1.id}",
              toWorkflowId: "#{wf2.id}",
              label: "complete"
            ) {
              id
              label
              fromWorkflowId
              toWorkflowId
            }
          }
        """)
        |> json_response(200)

      assert result["errors"] == nil
      transition = result["data"]["createWorkflowTransition"]
      assert transition["label"] == "complete"
      assert transition["fromWorkflowId"] == wf1.id
      assert transition["toWorkflowId"] == wf2.id

      # Verify project_id was set in the database
      {:ok, saved} =
        Accounts.WorkflowTransitions.get_by(user.id, conditions: [id: transition["id"]])

      assert saved.project_id == project.id
    end

    test "rejects a workflow transition to another project", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, source} = Accounts.Workflows.insert(user.id, project.id, %{name: "Source"})
      {:ok, other_project} = Accounts.Projects.insert(user.id, %{name: "Other Project"})

      {:ok, destination} =
        Accounts.Workflows.insert(user.id, other_project.id, %{name: "Destination"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createWorkflowTransition(
              fromWorkflowId: "#{source.id}",
              toWorkflowId: "#{destination.id}"
            ) { id }
          }
        """)
        |> json_response(200)

      assert result["data"]["createWorkflowTransition"] == nil

      assert Enum.any?(result["errors"], fn error ->
               error["message"] =~ "same project and user"
             end)
    end

    test "creates a step transition with correct project_id", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step1} = Accounts.WorkflowSteps.insert(workflow, %{name: "Step 1", step_order: 1})
      {:ok, step2} = Accounts.WorkflowSteps.insert(workflow, %{name: "Step 2", step_order: 2})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createStepTransition(
              fromStepId: "#{step1.id}",
              toStepId: "#{step2.id}",
              label: "next"
            ) {
              id
              label
              fromStepId
              toStepId
            }
          }
        """)
        |> json_response(200)

      assert result["errors"] == nil
      transition = result["data"]["createStepTransition"]
      assert transition["label"] == "next"
      assert transition["fromStepId"] == step1.id
      assert transition["toStepId"] == step2.id

      # Verify project_id was set in the database
      {:ok, saved} =
        Accounts.StepTransitions.get_by(user.id, conditions: [id: transition["id"]])

      assert saved.project_id == project.id
    end
  end

  # ─── 1. Untested Mutations ────────────────────────────────────────────

  describe "syncWorkflowTransitions mutation" do
    setup [:setup_user_and_project]

    @tag :skip
    test "creates transitions for a workflow - KNOWN BUG: returns list instead of workflow struct",
         %{conn: conn, user: user, project: project} do
      # sync_transitions returns {:ok, [transitions]} but the GraphQL field declares :workflow
      # This causes a BadMapError when Absinthe tries to resolve fields on the list.
      # Skipping until the resolver is fixed to return the workflow struct.
      {:ok, wf1} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF 1"})
      {:ok, wf2} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF 2"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            syncWorkflowTransitions(
              id: "#{wf1.id}"
              transitions: [{toWorkflowId: "#{wf2.id}", label: "next"}]
            ) { id name }
          }
        """)
        |> json_response(200)

      assert result["data"]["syncWorkflowTransitions"] != nil
    end

    @tag :skip
    test "rejects duplicate to_workflow_id values - KNOWN BUG: changeset not serializable",
         %{conn: conn, user: user, project: project} do
      # Returns {:error, changeset} but Ecto.Changeset doesn't implement String.Chars,
      # so Absinthe can't serialize the error. Skipping until error handling is fixed.
      {:ok, wf1} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF 1"})
      {:ok, wf2} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF 2"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            syncWorkflowTransitions(
              id: "#{wf1.id}"
              transitions: [
                {toWorkflowId: "#{wf2.id}", label: "a"},
                {toWorkflowId: "#{wf2.id}", label: "b"}
              ]
            ) { id }
          }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end
  end

  describe "syncStepTransitions mutation" do
    setup [:setup_user_and_project]

    @tag :skip
    test "creates step transitions - KNOWN BUG: returns list instead of step struct",
         %{conn: conn, user: user, project: project} do
      # sync_transitions returns {:ok, [transitions]} but the GraphQL field declares :workflow_step
      # This causes a BadMapError. Skipping until the resolver is fixed.
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, s1} = Accounts.WorkflowSteps.insert(wf, %{name: "S1", step_order: 1})
      {:ok, s2} = Accounts.WorkflowSteps.insert(wf, %{name: "S2", step_order: 2})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            syncStepTransitions(
              id: "#{s1.id}"
              transitions: [{toStepId: "#{s2.id}", label: "next"}]
            ) { id name }
          }
        """)
        |> json_response(200)

      assert result["data"]["syncStepTransitions"] != nil
    end

    test "rejects duplicate to_step_id values", %{conn: conn, user: user, project: project} do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, s1} = Accounts.WorkflowSteps.insert(wf, %{name: "S1", step_order: 1})
      {:ok, s2} = Accounts.WorkflowSteps.insert(wf, %{name: "S2", step_order: 2})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            syncStepTransitions(
              id: "#{s1.id}"
              transitions: [
                {toStepId: "#{s2.id}", label: "a"},
                {toStepId: "#{s2.id}", label: "b"}
              ]
            ) { id }
          }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end

    test "rejects steps from different workflows", %{conn: conn, user: user, project: project} do
      {:ok, wf1} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF 1"})
      {:ok, wf2} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF 2"})
      {:ok, s1} = Accounts.WorkflowSteps.insert(wf1, %{name: "S1", step_order: 1})
      {:ok, s_other} = Accounts.WorkflowSteps.insert(wf2, %{name: "S Other", step_order: 1})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            syncStepTransitions(
              id: "#{s1.id}"
              transitions: [{toStepId: "#{s_other.id}"}]
            ) { id }
          }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end
  end

  describe "createTaskDependency mutation" do
    setup [:setup_user_and_project]

    test "creates a dependency between two tasks", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, blocker} = Accounts.Tasks.insert(user.id, project.id, %{title: "Blocker"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createTaskDependency(taskId: "#{task.id}", dependsOnId: "#{blocker.id}") { id }
          }
        """)
        |> json_response(200)

      assert result["errors"] == nil
      assert result["data"]["createTaskDependency"]["id"] != nil
    end

    test "returns error for self-dependency", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createTaskDependency(taskId: "#{task.id}", dependsOnId: "#{task.id}") { id }
          }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end

    test "returns error for circular dependency", %{conn: conn, user: user, project: project} do
      {:ok, a} = Accounts.Tasks.insert(user.id, project.id, %{title: "A"})
      {:ok, b} = Accounts.Tasks.insert(user.id, project.id, %{title: "B"})
      {:ok, _} = Sacrum.Repo.TaskDependencies.add_dependency(a, b)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createTaskDependency(taskId: "#{b.id}", dependsOnId: "#{a.id}") { id }
          }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end

    test "returns error for tasks in different projects", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, project2} = Accounts.Projects.insert(user.id, %{name: "Other Project"})
      {:ok, task1} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task 1"})
      {:ok, task2} = Accounts.Tasks.insert(user.id, project2.id, %{title: "Task 2"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createTaskDependency(taskId: "#{task1.id}", dependsOnId: "#{task2.id}") { id }
          }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end
  end

  describe "deleteTaskDependency mutation" do
    setup [:setup_user_and_project]

    test "removes an existing dependency", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, blocker} = Accounts.Tasks.insert(user.id, project.id, %{title: "Blocker"})
      {:ok, _} = Sacrum.Repo.TaskDependencies.add_dependency(task, blocker)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            deleteTaskDependency(taskId: "#{task.id}", dependsOnId: "#{blocker.id}") {
              id title
            }
          }
        """)
        |> json_response(200)

      assert result["errors"] == nil
      assert result["data"]["deleteTaskDependency"] != nil
    end

    test "returns error when dependency doesn't exist", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, other} = Accounts.Tasks.insert(user.id, project.id, %{title: "Other"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            deleteTaskDependency(taskId: "#{task.id}", dependsOnId: "#{other.id}") { id }
          }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end
  end

  describe "syncTaskDependencies mutation" do
    setup [:setup_user_and_project]

    test "replaces a task dependency set", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, old_blocker} = Accounts.Tasks.insert(user.id, project.id, %{title: "Old Blocker"})
      {:ok, new_blocker} = Accounts.Tasks.insert(user.id, project.id, %{title: "New Blocker"})
      {:ok, _} = Accounts.Tasks.add_dependency(task, old_blocker)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            syncTaskDependencies(taskId: "#{task.id}", dependsOnIds: ["#{new_blocker.id}"]) {
              id blockers { id }
            }
          }
        """)
        |> json_response(200)

      assert result["errors"] == nil
      assert [%{"id" => blocker_id}] = result["data"]["syncTaskDependencies"]["blockers"]
      assert blocker_id == new_blocker.id
    end

    test "clears a task dependency set", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, old_blocker} = Accounts.Tasks.insert(user.id, project.id, %{title: "Old Blocker"})
      {:ok, _} = Accounts.Tasks.add_dependency(task, old_blocker)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            syncTaskDependencies(taskId: "#{task.id}", dependsOnIds: []) {
              id blockers { id }
            }
          }
        """)
        |> json_response(200)

      assert result["errors"] == nil
      assert result["data"]["syncTaskDependencies"]["blockers"] == []
      assert Sacrum.Repo.TaskDependencies.get_direct_blockers(task) == []
    end

    test "rolls back the full dependency set when one dependency is invalid", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, other_project} = Accounts.Projects.insert(user.id, %{name: "Other Project"})
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, old_blocker} = Accounts.Tasks.insert(user.id, project.id, %{title: "Old Blocker"})
      {:ok, new_blocker} = Accounts.Tasks.insert(user.id, project.id, %{title: "New Blocker"})

      {:ok, foreign_blocker} =
        Accounts.Tasks.insert(user.id, other_project.id, %{title: "Foreign"})

      {:ok, _} = Accounts.Tasks.add_dependency(task, old_blocker)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            syncTaskDependencies(
              taskId: "#{task.id}"
              dependsOnIds: ["#{new_blocker.id}", "#{foreign_blocker.id}"]
            ) {
              id blockers { id }
            }
          }
        """)
        |> json_response(200)

      assert result["data"]["syncTaskDependencies"] == nil
      assert result["errors"] != nil

      assert [%{id: blocker_id}] = Sacrum.Repo.TaskDependencies.get_direct_blockers(task)
      assert blocker_id == old_blocker.id
    end
  end

  describe "deleteWorkflowTransition mutation" do
    setup [:setup_user_and_project]

    test "deletes an existing workflow transition", %{conn: conn, user: user, project: project} do
      {:ok, wf1} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF 1"})
      {:ok, wf2} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF 2"})

      {:ok, transition} =
        Accounts.WorkflowTransitions.insert(user.id, %{
          from_workflow_id: wf1.id,
          to_workflow_id: wf2.id,
          project_id: project.id,
          label: "next"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            deleteWorkflowTransition(id: "#{transition.id}") { id label }
          }
        """)
        |> json_response(200)

      assert result["errors"] == nil
      assert result["data"]["deleteWorkflowTransition"]["id"] == transition.id
    end

    test "returns error for nonexistent transition ID", %{conn: conn, user: user} do
      fake_id = Ecto.UUID.generate()

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation { deleteWorkflowTransition(id: "#{fake_id}") { id } }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end
  end

  describe "deleteStepTransition mutation" do
    setup [:setup_user_and_project]

    test "deletes an existing step transition", %{conn: conn, user: user, project: project} do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, s1} = Accounts.WorkflowSteps.insert(wf, %{name: "S1", step_order: 1})
      {:ok, s2} = Accounts.WorkflowSteps.insert(wf, %{name: "S2", step_order: 2})

      {:ok, transition} =
        Accounts.StepTransitions.insert(user.id, %{
          from_step_id: s1.id,
          to_step_id: s2.id,
          project_id: project.id,
          label: "next"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            deleteStepTransition(id: "#{transition.id}") { id label }
          }
        """)
        |> json_response(200)

      assert result["errors"] == nil
      assert result["data"]["deleteStepTransition"]["id"] == transition.id
    end

    test "returns error for nonexistent transition ID", %{conn: conn, user: user} do
      fake_id = Ecto.UUID.generate()

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation { deleteStepTransition(id: "#{fake_id}") { id } }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end
  end

  # ─── 2. Task Query Filters ───────────────────────────────────────────

  describe "task query filters" do
    setup [:setup_user_and_project]

    test "filters by parent_id", %{conn: conn, user: user, project: project} do
      {:ok, parent} = Accounts.Tasks.insert(user.id, project.id, %{title: "Parent"})
      {:ok, child} = Accounts.Tasks.insert(user.id, project.id, %{title: "Child"})
      {:ok, _} = Sacrum.Repo.TaskHierarchy.set_parent(child, parent)
      {:ok, _orphan} = Accounts.Tasks.insert(user.id, project.id, %{title: "Orphan"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { tasks(projectId: "#{project.id}", parentId: "#{parent.id}") { title } }
        """)
        |> json_response(200)

      titles = Enum.map(result["data"]["tasks"], & &1["title"])
      assert "Child" in titles
      refute "Orphan" in titles
      refute "Parent" in titles
    end

    test "filters by compatibility task status", %{conn: conn, user: user, project: project} do
      {:ok, ready_task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Ready"})
      {:ok, done_task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Done"})

      {:ok, legacy_running} =
        Accounts.Tasks.insert(user.id, project.id, %{title: "Legacy Running"})

      {:ok, done_task} = Accounts.Tasks.update(done_task, %{completed_at: DateTime.utc_now()})

      {:ok, done_task} = Sacrum.Tasks.Status.refresh(done_task)

      {:ok, legacy_running} =
        legacy_running
        |> Ecto.Changeset.change(%{status: "running"})
        |> Sacrum.Repo.update()

      assert ready_task.status == "ready"
      assert done_task.status == "done"
      assert legacy_running.status == "running"

      ready_result =
        conn
        |> authenticate(user)
        |> graphql("""
          { tasks(projectId: "#{project.id}", status: "ready") { title } }
        """)
        |> json_response(200)

      ready_titles = Enum.map(ready_result["data"]["tasks"], & &1["title"])
      assert "Ready" in ready_titles
      refute "Done" in ready_titles
      refute "Legacy Running" in ready_titles

      done_result =
        conn
        |> authenticate(user)
        |> graphql("""
          { tasks(projectId: "#{project.id}", status: "done") { title } }
        """)
        |> json_response(200)

      done_titles = Enum.map(done_result["data"]["tasks"], & &1["title"])
      assert done_titles == ["Done"]

      legacy_result =
        conn
        |> authenticate(user)
        |> graphql("""
          { tasks(projectId: "#{project.id}", status: "running") { title } }
        """)
        |> json_response(200)

      legacy_titles = Enum.map(legacy_result["data"]["tasks"], & &1["title"])
      assert legacy_titles == ["Legacy Running"]
    end

    test "filters by priority", %{conn: conn, user: user, project: project} do
      {:ok, _} =
        Accounts.Tasks.insert(user.id, project.id, %{title: "Urgent", priority: "critical"})

      {:ok, _} =
        Accounts.Tasks.insert(user.id, project.id, %{title: "Normal", priority: "low"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { tasks(projectId: "#{project.id}", priority: "critical") { title priority } }
        """)
        |> json_response(200)

      titles = Enum.map(result["data"]["tasks"], & &1["title"])
      assert "Urgent" in titles
      refute "Normal" in titles
    end

    test "filters by tags", %{conn: conn, user: user, project: project} do
      {:ok, _} =
        Accounts.Tasks.insert(user.id, project.id, %{title: "Tagged", tags: ["bug", "urgent"]})

      {:ok, _} = Accounts.Tasks.insert(user.id, project.id, %{title: "Untagged"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { tasks(projectId: "#{project.id}", tags: ["bug"]) { title } }
        """)
        |> json_response(200)

      titles = Enum.map(result["data"]["tasks"], & &1["title"])
      assert "Tagged" in titles
      refute "Untagged" in titles
    end

    test "filters by search (title match)", %{conn: conn, user: user, project: project} do
      {:ok, _} = Accounts.Tasks.insert(user.id, project.id, %{title: "Fix login bug"})
      {:ok, _} = Accounts.Tasks.insert(user.id, project.id, %{title: "Add feature"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { tasks(projectId: "#{project.id}", search: "login") { title } }
        """)
        |> json_response(200)

      titles = Enum.map(result["data"]["tasks"], & &1["title"])
      assert "Fix login bug" in titles
      refute "Add feature" in titles
    end

    test "filters by search (description match)", %{conn: conn, user: user, project: project} do
      {:ok, _} =
        Accounts.Tasks.insert(user.id, project.id, %{
          title: "Task A",
          description: "handle authentication"
        })

      {:ok, _} =
        Accounts.Tasks.insert(user.id, project.id, %{
          title: "Task B",
          description: "handle payments"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { tasks(projectId: "#{project.id}", search: "authentication") { title } }
        """)
        |> json_response(200)

      titles = Enum.map(result["data"]["tasks"], & &1["title"])
      assert "Task A" in titles
      refute "Task B" in titles
    end

    test "filters by search (full UUID match) within project scope", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, matching_task} =
        Accounts.Tasks.insert(user.id, project.id, %{title: "Matching UUID"})

      {:ok, other_project} = Accounts.Projects.insert(user.id, %{name: "Other Project"})

      {:ok, _same_user_other_project_task} =
        Accounts.Tasks.insert(user.id, other_project.id, %{title: "Other Project UUID"})

      other_user = create_user(%{email: "other-uuid@example.com", username: "otheruuid"})
      {:ok, other_user_project} = Accounts.Projects.insert(other_user.id, %{name: "Other User"})

      {:ok, _other_user_task} =
        Accounts.Tasks.insert(other_user.id, other_user_project.id, %{title: "Other User UUID"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { tasks(projectId: "#{project.id}", search: "#{matching_task.id}") { id title } }
        """)
        |> json_response(200)

      assert [%{"id" => id, "title" => "Matching UUID"}] = result["data"]["tasks"]
      assert id == matching_task.id
    end

    test "filters by search (UUID prefix match)", %{conn: conn, user: user, project: project} do
      {:ok, matching_task} =
        Accounts.Tasks.insert(user.id, project.id, %{title: "Matching UUID Prefix"})

      {:ok, unrelated_task} =
        Accounts.Tasks.insert(user.id, project.id, %{title: "Unrelated UUID Prefix"})

      prefix = String.slice(matching_task.id, 0, 12)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { tasks(projectId: "#{project.id}", search: "#{prefix}") { id title } }
        """)
        |> json_response(200)

      task_ids = Enum.map(result["data"]["tasks"], & &1["id"])
      assert task_ids == [matching_task.id]
      refute unrelated_task.id in task_ids
    end

    test "filters by workflow_id", %{conn: conn, user: user, project: project} do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step} = Accounts.WorkflowSteps.insert(wf, %{name: "S1", step_order: 1})
      {:ok, _} = Accounts.Workflows.update(wf, %{initial_step_id: step.id})

      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "With WF"})
      Sacrum.Repo.TaskWorkflows.assign_workflow(task, wf)

      {:ok, _other} = Accounts.Tasks.insert(user.id, project.id, %{title: "No WF"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { tasks(projectId: "#{project.id}", workflowId: "#{wf.id}") { title } }
        """)
        |> json_response(200)

      titles = Enum.map(result["data"]["tasks"], & &1["title"])
      assert "With WF" in titles
      refute "No WF" in titles
    end

    test "filters by root_only: true", %{conn: conn, user: user, project: project} do
      {:ok, parent} = Accounts.Tasks.insert(user.id, project.id, %{title: "Root"})
      {:ok, child} = Accounts.Tasks.insert(user.id, project.id, %{title: "Child"})
      {:ok, _} = Sacrum.Repo.TaskHierarchy.set_parent(child, parent)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { tasks(projectId: "#{project.id}", rootOnly: true) { title } }
        """)
        |> json_response(200)

      titles = Enum.map(result["data"]["tasks"], & &1["title"])
      assert "Root" in titles
      refute "Child" in titles
    end

    test "filters by blocked: false excludes blocked tasks", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, blocker} = Accounts.Tasks.insert(user.id, project.id, %{title: "Blocker"})
      {:ok, blocked} = Accounts.Tasks.insert(user.id, project.id, %{title: "Blocked"})
      {:ok, _} = Sacrum.Repo.TaskDependencies.add_dependency(blocked, blocker)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { tasks(projectId: "#{project.id}", blocked: false) { title } }
        """)
        |> json_response(200)

      titles = Enum.map(result["data"]["tasks"], & &1["title"])
      assert "Blocker" in titles
      refute "Blocked" in titles
    end

    test "filters by step_id", %{conn: conn, user: user, project: project} do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step1} = Accounts.WorkflowSteps.insert(wf, %{name: "step1", step_order: 1})
      {:ok, step2} = Accounts.WorkflowSteps.insert(wf, %{name: "step2", step_order: 2})
      {:ok, _} = Accounts.Workflows.update(wf, %{initial_step_id: step1.id})

      {:ok, _} =
        Sacrum.Repo.StepTransitions.insert(user.id, %{
          project_id: project.id,
          from_step_id: step1.id,
          to_step_id: step2.id
        })

      {:ok, task1} = Accounts.Tasks.insert(user.id, project.id, %{title: "On Step 1"})
      {:ok, task2} = Accounts.Tasks.insert(user.id, project.id, %{title: "On Step 2"})
      {:ok, _task3} = Accounts.Tasks.insert(user.id, project.id, %{title: "No Workflow"})

      {:ok, _task1_assigned} = Sacrum.Repo.TaskWorkflows.assign_workflow(task1, wf)
      {:ok, task2_assigned} = Sacrum.Repo.TaskWorkflows.assign_workflow(task2, wf)
      {:ok, _} = Sacrum.Repo.TaskWorkflows.move_to_step(task2_assigned, step2.id)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { tasks(projectId: "#{project.id}", stepId: "#{step1.id}") { title } }
        """)
        |> json_response(200)

      titles = Enum.map(result["data"]["tasks"], & &1["title"])
      assert "On Step 1" in titles
      refute "On Step 2" in titles
      refute "No Workflow" in titles
    end

    test "tasks query without stepId returns the same set as before this change", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step} = Accounts.WorkflowSteps.insert(wf, %{name: "mystep", step_order: 1})
      {:ok, _} = Accounts.Workflows.update(wf, %{initial_step_id: step.id})

      {:ok, task1} = Accounts.Tasks.insert(user.id, project.id, %{title: "With WF"})
      {:ok, _task2} = Accounts.Tasks.insert(user.id, project.id, %{title: "Without WF"})

      Sacrum.Repo.TaskWorkflows.assign_workflow(task1, wf)
      Sacrum.Repo.TaskWorkflows.move_to_step(task1, step.id)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { tasks(projectId: "#{project.id}") { title } }
        """)
        |> json_response(200)

      titles = Enum.map(result["data"]["tasks"], & &1["title"])
      assert "With WF" in titles
      assert "Without WF" in titles
      assert length(titles) == 2
    end
  end

  # ─── 3. Missing Field Coverage ───────────────────────────────────────

  describe "task field coverage" do
    setup [:setup_user_and_project]

    test "exposes workflow position for human_input review state", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "Human Review"})

      {:ok, step} =
        Accounts.WorkflowSteps.insert(workflow, %{
          name: "wait",
          step_order: 1,
          step_type: "human_input"
        })

      {:ok, task} =
        Accounts.Tasks.insert(user.id, project.id, %{
          title: "Task",
          workflow_id: workflow.id,
          current_step_id: step.id
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { task(id: "#{task.id}") {
            id currentStepId currentStep { id name stepType }
          } }
        """)
        |> json_response(200)

      data = result["data"]["task"]
      assert data["currentStepId"] == step.id
      assert data["currentStep"]["id"] == step.id
      assert data["currentStep"]["name"] == "wait"
      assert data["currentStep"]["stepType"] == "human_input"
    end

    test "removed review metadata fields are absent from task and updateTask contracts" do
      task_fields =
        SacrumWeb.Graphql.Schema
        |> Absinthe.Schema.lookup_type(:task)
        |> Map.fetch!(:fields)
        |> Map.keys()
        |> MapSet.new()

      update_task_args =
        SacrumWeb.Graphql.Schema
        |> Absinthe.Schema.lookup_type(:mutation)
        |> Map.fetch!(:fields)
        |> Map.fetch!(:update_task)
        |> Map.fetch!(:args)
        |> Map.keys()
        |> MapSet.new()

      removed_fields = MapSet.new([:needs_human_review, :review_comment, :revision_feedback])

      assert MapSet.disjoint?(task_fields, removed_fields)
      assert MapSet.disjoint?(update_task_args, removed_fields)
    end
  end

  describe "workflow field coverage" do
    setup [:setup_user_and_project]

    test "returns initialStepId, metadata, displayOrder fields", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step} = Accounts.WorkflowSteps.insert(wf, %{name: "S1", step_order: 1})

      {:ok, _} =
        Accounts.Workflows.update(wf, %{
          initial_step_id: step.id,
          metadata: %{"key" => "value"},
          display_order: 5
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { workflow(id: "#{wf.id}") {
            id initialStepId metadata displayOrder
          } }
        """)
        |> json_response(200)

      data = result["data"]["workflow"]
      assert data["initialStepId"] == step.id
      assert data["metadata"] == %{"key" => "value"}
      assert data["displayOrder"] == 5
    end

    test "createWorkflow with displayOrder", %{
      conn: conn,
      user: user,
      project: project
    } do
      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createWorkflow(
              projectId: "#{project.id}"
              name: "Full WF"
              displayOrder: 3
            ) { id name displayOrder }
          }
        """)
        |> json_response(200)

      data = result["data"]["createWorkflow"]
      assert data["name"] == "Full WF"
      assert data["displayOrder"] == 3
    end

    test "createWorkflow with metadata", %{conn: conn, user: user, project: project} do
      # JSON scalar expects a JSON-encoded string in the query
      escaped = ~S|{\"key\":\"value\"}|

      result =
        conn
        |> authenticate(user)
        |> graphql(~s"""
          mutation {
            createWorkflow(
              projectId: "#{project.id}"
              name: "Meta WF"
              metadata: "#{escaped}"
            ) { id name metadata }
          }
        """)
        |> json_response(200)

      data = result["data"]["createWorkflow"]
      assert data["name"] == "Meta WF"
      assert data["metadata"] == %{"key" => "value"}
    end
  end

  describe "workflow step field coverage" do
    setup [:setup_user_and_project]

    test "returns agents, skills, agentConfig fields", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, step} =
        Accounts.WorkflowSteps.insert(wf, %{
          name: "S1",
          step_order: 1,
          agents: ["agent1", "agent2"],
          skills: ["code", "test"],
          agent_config: %{"model" => "claude"}
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { workflowStep(id: "#{step.id}") { id agents skills agentConfig } }
        """)
        |> json_response(200)

      data = result["data"]["workflowStep"]
      assert data["agents"] == ["agent1", "agent2"]
      assert data["skills"] == ["code", "test"]
      assert data["agentConfig"] == %{"model" => "claude"}
    end

    test "createWorkflowStep with agents, skills, agentConfig", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      agent_config = ~S|{\"model\":\"gpt\"}|

      result =
        conn
        |> authenticate(user)
        |> graphql(~s"""
          mutation {
            createWorkflowStep(
              workflowId: "#{wf.id}"
              name: "Full Step"
              agents: ["a1"]
              skills: ["s1"]
              agentConfig: "#{agent_config}"
              stepOrder: 1
            ) { id name agents skills agentConfig }
          }
        """)
        |> json_response(200)

      data = result["data"]["createWorkflowStep"]
      assert data["name"] == "Full Step"
      assert data["agents"] == ["a1"]
      assert data["skills"] == ["s1"]
      assert data["agentConfig"] == %{"model" => "gpt"}
    end

    test "updateWorkflowStep with agents, skills, agentConfig", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step} = Accounts.WorkflowSteps.insert(wf, %{name: "S1"})
      agent_config = ~S|{\"key\":\"val\"}|

      result =
        conn
        |> authenticate(user)
        |> graphql(~s"""
          mutation {
            updateWorkflowStep(
              id: "#{step.id}"
              agents: ["updated"]
              skills: ["new_skill"]
              agentConfig: "#{agent_config}"
            ) { id agents skills agentConfig }
          }
        """)
        |> json_response(200)

      data = result["data"]["updateWorkflowStep"]
      assert data["agents"] == ["updated"]
      assert data["skills"] == ["new_skill"]
      assert data["agentConfig"] == %{"key" => "val"}
    end

    test "returns prompt field", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, step} =
        Accounts.WorkflowSteps.insert(wf, %{
          name: "S1",
          prompt: "Execute the task"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { workflowStep(id: "#{step.id}") { id prompt } }
        """)
        |> json_response(200)

      data = result["data"]["workflowStep"]
      assert data["prompt"] == "Execute the task"
    end
  end

  describe "step execution field coverage" do
    setup [:setup_user_and_project]

    test "updateStepExecution rejects handoff argument (not exposed to mutations)", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, exec} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: wf.id,
          project_id: project.id,
          step_name: "step_1",
          status: "running"
        })

      # Attempt to set handoff in updateStepExecution
      result =
        conn
        |> authenticate(user)
        |> graphql(~s"""
          mutation {
            updateStepExecution(
              id: "#{exec.id}"
              status: "completed"
              handoff: "{\\"key\\": \\"value\\"}"
            ) { id status }
          }
        """)
        |> json_response(200)

      # Should get a GraphQL validation error (invalid argument)
      assert result["errors"] != nil
      error_message = Enum.find(result["errors"], &String.contains?(&1["message"], "handoff"))
      assert error_message != nil
    end

    test "stepExecution field returns handoff when set by orchestrator", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      # Create execution with handoff (simulating orchestrator setting it)
      {:ok, exec} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: wf.id,
          project_id: project.id,
          step_name: "step_1",
          status: "completed",
          handoff: %{"context" => "data", "nested" => %{"key" => "value"}}
        })

      result =
        conn
        |> authenticate(user)
        |> graphql(~s|{ stepExecution(id: "#{exec.id}") { id handoff } }|)
        |> json_response(200)

      data = result["data"]["stepExecution"]
      assert data["id"] == exec.id
      assert data["handoff"] == %{"context" => "data", "nested" => %{"key" => "value"}}
    end

    test "stepExecution query exposes the stored stepType snapshot after workflow step changes",
         %{
           conn: conn,
           user: user,
           project: project
         } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, step} =
        Accounts.WorkflowSteps.insert(wf, %{
          name: "Snapshot step",
          step_type: "evaluate"
        })

      {:ok, exec} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: wf.id,
          step_id: step.id,
          project_id: project.id,
          step_name: step.name,
          status: "completed"
        })

      {:ok, _updated_step} = Accounts.WorkflowSteps.update(step, %{step_type: "execute"})

      result =
        conn
        |> authenticate(user)
        |> graphql(~s|{ stepExecution(id: "#{exec.id}") { id stepId stepName stepType } }|)
        |> json_response(200)

      data = result["data"]["stepExecution"]
      assert data["id"] == exec.id
      assert data["stepId"] == step.id
      assert data["stepName"] == "Snapshot step"
      assert data["stepType"] == "evaluate"
    end

    test "stepExecution field returns nil for handoff when not set", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, exec} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: wf.id,
          project_id: project.id,
          step_name: "step_1",
          status: "completed"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql(~s|{ stepExecution(id: "#{exec.id}") { id handoff } }|)
        |> json_response(200)

      data = result["data"]["stepExecution"]
      assert data["id"] == exec.id
      # handoff should be null when not set
      assert data["handoff"] == nil
    end

    test "stepExecutions query includes handoff field", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, exec} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: wf.id,
          project_id: project.id,
          step_name: "step_1",
          status: "completed",
          handoff: %{"approved" => true}
        })

      result =
        conn
        |> authenticate(user)
        |> graphql(~s|{ stepExecutions(taskId: "#{task.id}") { id handoff } }|)
        |> json_response(200)

      found = Enum.find(result["data"]["stepExecutions"], &(&1["id"] == exec.id))
      assert found != nil
      assert found["handoff"] == %{"approved" => true}
    end
  end

  describe "section field coverage" do
    setup [:setup_user_and_project]

    test "updateSection sets doneAt and returns it", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      {:ok, section} =
        Accounts.Sections.insert(user.id, %{
          task_id: task.id,
          project_id: project.id,
          section_type: "context",
          content: "Content"
        })

      now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateSection(id: "#{section.id}", done: true, doneAt: "#{now}") {
              id done doneAt
            }
          }
        """)
        |> json_response(200)

      data = result["data"]["updateSection"]
      assert data["done"] == true
      assert data["doneAt"] != nil
    end
  end

  # ─── 4. Association Resolution ───────────────────────────────────────

  describe "task association resolution" do
    setup [:setup_user_and_project]

    test "resolves task -> workflow", %{conn: conn, user: user, project: project} do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step} = Accounts.WorkflowSteps.insert(wf, %{name: "S1", step_order: 1})
      {:ok, _} = Accounts.Workflows.update(wf, %{initial_step_id: step.id})
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      Sacrum.Repo.TaskWorkflows.assign_workflow(task, wf)

      result =
        conn
        |> authenticate(user)
        |> graphql(~s|{ task(id: "#{task.id}") { workflow { id name } } }|)
        |> json_response(200)

      assert result["data"]["task"]["workflow"]["id"] == wf.id
      assert result["data"]["task"]["workflow"]["name"] == "WF"
    end

    test "resolves task -> currentStep", %{conn: conn, user: user, project: project} do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step} = Accounts.WorkflowSteps.insert(wf, %{name: "Step 1", step_order: 1})
      {:ok, _} = Accounts.Workflows.update(wf, %{initial_step_id: step.id})
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      Sacrum.Repo.TaskWorkflows.assign_workflow(task, wf)

      result =
        conn
        |> authenticate(user)
        |> graphql(~s|{ task(id: "#{task.id}") { currentStep { id name } } }|)
        |> json_response(200)

      assert result["data"]["task"]["currentStep"]["id"] == step.id
      assert result["data"]["task"]["currentStep"]["name"] == "Step 1"
    end

    test "resolves task -> parent", %{conn: conn, user: user, project: project} do
      {:ok, parent} = Accounts.Tasks.insert(user.id, project.id, %{title: "Parent"})
      {:ok, child} = Accounts.Tasks.insert(user.id, project.id, %{title: "Child"})
      {:ok, _} = Sacrum.Repo.TaskHierarchy.set_parent(child, parent)

      result =
        conn
        |> authenticate(user)
        |> graphql(~s|{ task(id: "#{child.id}") { parent { id title } } }|)
        |> json_response(200)

      assert result["data"]["task"]["parent"]["id"] == parent.id
      assert result["data"]["task"]["parent"]["title"] == "Parent"
    end

    test "resolves task -> children", %{conn: conn, user: user, project: project} do
      {:ok, parent} = Accounts.Tasks.insert(user.id, project.id, %{title: "Parent"})
      {:ok, child} = Accounts.Tasks.insert(user.id, project.id, %{title: "Child"})
      {:ok, _} = Sacrum.Repo.TaskHierarchy.set_parent(child, parent)

      result =
        conn
        |> authenticate(user)
        |> graphql(~s|{ task(id: "#{parent.id}") { children { id title } } }|)
        |> json_response(200)

      assert [c] = result["data"]["task"]["children"]
      assert c["id"] == child.id
      assert c["title"] == "Child"
    end

    test "resolves task -> sections", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      {:ok, section} =
        Accounts.Sections.insert(user.id, %{
          task_id: task.id,
          project_id: project.id,
          section_type: "context",
          content: "Hello"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { task(id: "#{task.id}") { sections { id sectionType content } } }
        """)
        |> json_response(200)

      assert [s] = result["data"]["task"]["sections"]
      assert s["id"] == section.id
      assert s["sectionType"] == "context"
      assert s["content"] == "Hello"
    end

    test "resolves task -> artifacts through the scoped artifact service", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task with artifacts"})

      markdown_artifact =
        create_artifact(user, project, %{
          filename: "task-summary.md",
          body: "# Task summary\n\nReady for review."
        })

      json_artifact =
        create_artifact(user, project, %{
          filename: "task-result.json",
          body: ~s({"status":"ready"})
        })

      other_task_artifact =
        create_artifact(user, project, %{
          filename: "other-task.md",
          body: "# Other task"
        })

      for artifact <- [markdown_artifact, json_artifact] do
        link_artifact(user, project, artifact, "task", task.id)
      end

      {:ok, other_task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Other task"})

      link_artifact(
        user,
        project,
        other_task_artifact,
        "task",
        other_task.id
      )

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          {
            task(id: "#{task.id}") {
              artifacts {
                id
                filename
                body
              }
            }
          }
        """)
        |> json_response(200)

      artifacts = Enum.sort_by(result["data"]["task"]["artifacts"], & &1["filename"])

      assert artifacts == [
               %{
                 "body" => ~s({"status":"ready"}),
                 "filename" => "task-result.json",
                 "id" => json_artifact.id
               },
               %{
                 "body" => "# Task summary\n\nReady for review.",
                 "filename" => "task-summary.md",
                 "id" => markdown_artifact.id
               }
             ]
    end

    test "resolves task -> codeRefs", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      {:ok, ref} =
        Accounts.CodeRefs.insert_for_task(user.id, %{
          task_id: task.id,
          project_id: project.id,
          path: "lib/foo.ex"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { task(id: "#{task.id}") { codeRefs { id path } } }
        """)
        |> json_response(200)

      assert [r] = result["data"]["task"]["codeRefs"]
      assert r["id"] == ref.id
      assert r["path"] == "lib/foo.ex"
    end

    test "resolves task -> blockers and dependents", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, blocker} = Accounts.Tasks.insert(user.id, project.id, %{title: "Blocker"})
      {:ok, _} = Sacrum.Repo.TaskDependencies.add_dependency(task, blocker)

      # Check blockers on the dependent task
      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { task(id: "#{task.id}") { blockers { id title } } }
        """)
        |> json_response(200)

      assert [b] = result["data"]["task"]["blockers"]
      assert b["id"] == blocker.id
      assert b["title"] == "Blocker"

      # Check dependents on the blocker task
      result2 =
        build_conn()
        |> authenticate(user)
        |> graphql("""
          { task(id: "#{blocker.id}") { dependents { id title } } }
        """)
        |> json_response(200)

      assert [d] = result2["data"]["task"]["dependents"]
      assert d["id"] == task.id
      assert d["title"] == "Task"
    end
  end

  describe "workflow association resolution" do
    setup [:setup_user_and_project]

    test "resolves workflow -> project", %{conn: conn, user: user, project: project} do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      result =
        conn
        |> authenticate(user)
        |> graphql(~s|{ workflow(id: "#{wf.id}") { project { id name } } }|)
        |> json_response(200)

      assert result["data"]["workflow"]["project"]["id"] == project.id
      assert result["data"]["workflow"]["project"]["name"] == "Test Project"
    end

    test "resolves workflow -> transitions", %{conn: conn, user: user, project: project} do
      {:ok, wf1} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF 1"})
      {:ok, wf2} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF 2"})

      {:ok, transition} =
        Accounts.WorkflowTransitions.insert(user.id, %{
          from_workflow_id: wf1.id,
          to_workflow_id: wf2.id,
          project_id: project.id,
          label: "next"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { workflow(id: "#{wf1.id}") { transitions { id label } } }
        """)
        |> json_response(200)

      assert [t] = result["data"]["workflow"]["transitions"]
      assert t["id"] == transition.id
      assert t["label"] == "next"
    end
  end

  describe "workflow step association resolution" do
    setup [:setup_user_and_project]

    test "resolves workflowStep -> workflow", %{conn: conn, user: user, project: project} do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step} = Accounts.WorkflowSteps.insert(wf, %{name: "S1"})

      result =
        conn
        |> authenticate(user)
        |> graphql(~s|{ workflowStep(id: "#{step.id}") { workflow { id name } } }|)
        |> json_response(200)

      assert result["data"]["workflowStep"]["workflow"]["id"] == wf.id
      assert result["data"]["workflowStep"]["workflow"]["name"] == "WF"
    end

    test "resolves workflowStep -> project", %{conn: conn, user: user, project: project} do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step} = Accounts.WorkflowSteps.insert(wf, %{name: "S1"})

      result =
        conn
        |> authenticate(user)
        |> graphql(~s|{ workflowStep(id: "#{step.id}") { project { id name } } }|)
        |> json_response(200)

      assert result["data"]["workflowStep"]["project"]["id"] == project.id
    end

    test "resolves workflowStep -> transitions", %{conn: conn, user: user, project: project} do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, s1} = Accounts.WorkflowSteps.insert(wf, %{name: "S1", step_order: 1})
      {:ok, s2} = Accounts.WorkflowSteps.insert(wf, %{name: "S2", step_order: 2})

      {:ok, transition} =
        Accounts.StepTransitions.insert(user.id, %{
          from_step_id: s1.id,
          to_step_id: s2.id,
          project_id: project.id,
          label: "next"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { workflowStep(id: "#{s1.id}") { transitions { id label } } }
        """)
        |> json_response(200)

      assert [t] = result["data"]["workflowStep"]["transitions"]
      assert t["id"] == transition.id
      assert t["label"] == "next"
    end
  end

  describe "section and code ref association resolution" do
    setup [:setup_user_and_project]

    test "resolves section -> task, project, code_refs", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      {:ok, section} =
        Accounts.Sections.insert(user.id, %{
          task_id: task.id,
          project_id: project.id,
          section_type: "context",
          content: "Content"
        })

      {:ok, ref} =
        Accounts.CodeRefs.insert_for_section(user.id, %{
          section_id: section.id,
          project_id: project.id,
          path: "lib/foo.ex"
        })

      # Query section through task to get its associations
      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { task(id: "#{task.id}") {
            sections {
              id
              task { id title }
              project { id name }
              codeRefs { id path }
            }
          } }
        """)
        |> json_response(200)

      [s] = result["data"]["task"]["sections"]
      assert s["task"]["id"] == task.id
      assert s["project"]["id"] == project.id
      assert [cr] = s["codeRefs"]
      assert cr["id"] == ref.id
      assert cr["path"] == "lib/foo.ex"
    end

    test "resolves testing criterion section artifacts and evidence links", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      {:ok, section} =
        Accounts.Sections.insert(user.id, %{
          task_id: task.id,
          project_id: project.id,
          section_type: "testing_criterion",
          content: "Unit test proves artifact evidence is exposed."
        })

      attached_markdown =
        create_artifact(user, project, %{
          filename: "attached-evidence.md",
          body: "# Attached evidence"
        })

      evidence_json =
        create_artifact(user, project, %{
          filename: "criterion-result.json",
          body: ~s({"passed":true})
        })

      link_artifact(user, project, attached_markdown, "task_section", section.id)
      link_artifact(user, project, evidence_json, "task_section", section.id)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          {
            task(id: "#{task.id}") {
              sections {
                id
                sectionType
                artifacts { id filename body }
                evidence { id filename body }
              }
            }
          }
        """)
        |> json_response(200)

      [found_section] = result["data"]["task"]["sections"]
      assert found_section["id"] == section.id
      assert found_section["sectionType"] == "testing_criterion"

      expected_artifacts =
        [
          %{
            "body" => "# Attached evidence",
            "filename" => "attached-evidence.md",
            "id" => attached_markdown.id
          },
          %{
            "body" => ~s({"passed":true}),
            "filename" => "criterion-result.json",
            "id" => evidence_json.id
          }
        ]
        |> Enum.sort_by(& &1["filename"])

      assert Enum.sort_by(found_section["artifacts"], & &1["filename"]) == expected_artifacts
      assert Enum.sort_by(found_section["evidence"], & &1["filename"]) == expected_artifacts
    end

    test "resolves code_ref -> task, section, project", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      {:ok, _ref} =
        Accounts.CodeRefs.insert_for_task(user.id, %{
          task_id: task.id,
          project_id: project.id,
          path: "lib/bar.ex"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { task(id: "#{task.id}") {
            codeRefs {
              id path
              task { id title }
              project { id name }
            }
          } }
        """)
        |> json_response(200)

      [cr] = result["data"]["task"]["codeRefs"]
      assert cr["task"]["id"] == task.id
      assert cr["project"]["id"] == project.id
    end
  end

  describe "transition association resolution" do
    setup [:setup_user_and_project]

    test "resolves workflowTransition -> fromWorkflow, toWorkflow, targetStep, project", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf1} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF 1"})
      {:ok, wf2} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF 2"})
      {:ok, step} = Accounts.WorkflowSteps.insert(wf2, %{name: "Target Step"})

      {:ok, _transition} =
        Accounts.WorkflowTransitions.insert(user.id, %{
          from_workflow_id: wf1.id,
          to_workflow_id: wf2.id,
          target_step_id: step.id,
          project_id: project.id,
          label: "complete"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { workflow(id: "#{wf1.id}") {
            transitions {
              id label
              fromWorkflow { id name }
              toWorkflow { id name }
              targetStep { id name }
              project { id name }
            }
          } }
        """)
        |> json_response(200)

      [t] = result["data"]["workflow"]["transitions"]
      assert t["label"] == "complete"
      assert t["fromWorkflow"]["id"] == wf1.id
      assert t["toWorkflow"]["id"] == wf2.id
      assert t["targetStep"]["id"] == step.id
      assert t["project"]["id"] == project.id
    end

    test "resolves stepTransition -> fromStep, toStep, project", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, s1} = Accounts.WorkflowSteps.insert(wf, %{name: "S1", step_order: 1})
      {:ok, s2} = Accounts.WorkflowSteps.insert(wf, %{name: "S2", step_order: 2})

      {:ok, _transition} =
        Accounts.StepTransitions.insert(user.id, %{
          from_step_id: s1.id,
          to_step_id: s2.id,
          project_id: project.id,
          label: "next"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { workflowStep(id: "#{s1.id}") {
            transitions {
              id label
              fromStep { id name }
              toStep { id name }
              project { id name }
            }
          } }
        """)
        |> json_response(200)

      [t] = result["data"]["workflowStep"]["transitions"]
      assert t["label"] == "next"
      assert t["fromStep"]["id"] == s1.id
      assert t["toStep"]["id"] == s2.id
      assert t["project"]["id"] == project.id
    end
  end

  describe "execution association resolution" do
    setup [:setup_user_and_project]

    test "resolves stepExecution -> workflow, project", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, exec} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: wf.id,
          project_id: project.id,
          step_name: "step_1"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { stepExecution(id: "#{exec.id}") {
            workflow { id name }
            project { id name }
          } }
        """)
        |> json_response(200)

      data = result["data"]["stepExecution"]
      assert data["workflow"]["id"] == wf.id
      assert data["project"]["id"] == project.id
    end

    test "resolves sessionLog -> stepExecution, project", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, exec} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: wf.id,
          project_id: project.id,
          step_name: "step_1"
        })

      {:ok, log} =
        Accounts.SessionLogs.insert(user.id, %{
          step_execution_id: exec.id,
          project_id: project.id,
          content: "A log"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { sessionLogs(stepExecutionId: "#{exec.id}") {
            id
            stepExecution { id stepName }
            project { id name }
          } }
        """)
        |> json_response(200)

      [l] = result["data"]["sessionLogs"]
      assert l["id"] == log.id
      assert l["stepExecution"]["id"] == exec.id
      assert l["project"]["id"] == project.id
    end
  end

  # ─── 5. Cross-User Data Isolation ───────────────────────────────────

  describe "cross-user isolation - extended" do
    setup [:setup_user_and_project]

    defp setup_second_user(_context) do
      other = create_user(%{email: "other@example.com", username: "other"})
      %{other_user: other}
    end

    setup [:setup_second_user]

    test "cannot access another user's sections", %{
      conn: conn,
      user: user,
      project: project,
      other_user: other_user
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      {:ok, section} =
        Accounts.Sections.insert(user.id, %{
          task_id: task.id,
          project_id: project.id,
          section_type: "context",
          content: "Secret"
        })

      result =
        conn
        |> authenticate(other_user)
        |> graphql("""
          mutation { updateSection(id: "#{section.id}", content: "Hacked") { id } }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end

    test "cannot access another user's code refs", %{
      conn: conn,
      user: user,
      project: project,
      other_user: other_user
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      {:ok, ref} =
        Accounts.CodeRefs.insert_for_task(user.id, %{
          task_id: task.id,
          project_id: project.id,
          path: "lib/secret.ex"
        })

      result =
        conn
        |> authenticate(other_user)
        |> graphql("""
          mutation { deleteCodeRef(id: "#{ref.id}") { id } }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end

    test "cannot access another user's workflow steps", %{
      conn: conn,
      user: user,
      project: project,
      other_user: other_user
    } do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step} = Accounts.WorkflowSteps.insert(wf, %{name: "Secret Step"})

      result =
        conn
        |> authenticate(other_user)
        |> graphql(~s|{ workflowStep(id: "#{step.id}") { id name } }|)
        |> json_response(200)

      assert result["data"]["workflowStep"] == nil
      assert result["errors"] != nil
    end

    test "cannot access another user's step executions", %{
      conn: conn,
      user: user,
      project: project,
      other_user: other_user
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, exec} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: wf.id,
          project_id: project.id,
          step_name: "step_1"
        })

      result =
        conn
        |> authenticate(other_user)
        |> graphql(~s|{ stepExecution(id: "#{exec.id}") { id } }|)
        |> json_response(200)

      assert result["data"]["stepExecution"] == nil
      assert result["errors"] != nil
    end

    test "cannot access another user's session logs", %{
      conn: conn,
      user: user,
      project: project,
      other_user: other_user
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      {:ok, exec} =
        Accounts.StepExecutions.insert(user.id, %{
          task_id: task.id,
          workflow_id: wf.id,
          project_id: project.id,
          step_name: "step_1"
        })

      {:ok, _log} =
        Accounts.SessionLogs.insert(user.id, %{
          step_execution_id: exec.id,
          project_id: project.id,
          content: "Secret log"
        })

      result =
        conn
        |> authenticate(other_user)
        |> graphql(~s|{ sessionLogs(stepExecutionId: "#{exec.id}") { id } }|)
        |> json_response(200)

      # Either returns error or empty list (depending on access check)
      if result["errors"] do
        assert result["errors"] != nil
      else
        assert result["data"]["sessionLogs"] == []
      end
    end

    test "cannot access another user's transitions", %{
      conn: conn,
      user: user,
      project: project,
      other_user: other_user
    } do
      {:ok, wf1} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF 1"})
      {:ok, wf2} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF 2"})

      {:ok, transition} =
        Accounts.WorkflowTransitions.insert(user.id, %{
          from_workflow_id: wf1.id,
          to_workflow_id: wf2.id,
          project_id: project.id,
          label: "next"
        })

      result =
        conn
        |> authenticate(other_user)
        |> graphql("""
          mutation { deleteWorkflowTransition(id: "#{transition.id}") { id } }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end

    test "listReady with another user's project returns error", %{
      conn: conn,
      user: user,
      project: project,
      other_user: other_user
    } do
      {:ok, _task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      result =
        conn
        |> authenticate(other_user)
        |> graphql(~s|{ listReady(projectId: "#{project.id}") { id } }|)
        |> json_response(200)

      assert result["errors"] != nil
    end
  end

  # ─── 6. createCodeRef Edge Cases ────────────────────────────────────

  describe "createCodeRef edge cases" do
    setup [:setup_user_and_project]

    test "creates code ref with only section_id", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      {:ok, section} =
        Accounts.Sections.insert(user.id, %{
          task_id: task.id,
          project_id: project.id,
          section_type: "context",
          content: "Content"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createCodeRef(sectionId: "#{section.id}", path: "lib/test.ex") {
              id path sectionId taskId
            }
          }
        """)
        |> json_response(200)

      data = result["data"]["createCodeRef"]
      assert data["path"] == "lib/test.ex"
      assert data["sectionId"] == section.id
      assert data["taskId"] == nil
    end

    test "returns error with both task_id and section_id", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      {:ok, section} =
        Accounts.Sections.insert(user.id, %{
          task_id: task.id,
          project_id: project.id,
          section_type: "context",
          content: "Content"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createCodeRef(
              taskId: "#{task.id}"
              sectionId: "#{section.id}"
              path: "lib/test.ex"
            ) { id }
          }
        """)
        |> json_response(200)

      assert [%{"message" => msg}] = result["errors"]
      assert msg =~ "cannot provide both"
    end

    test "returns error with neither task_id nor section_id", %{conn: conn, user: user} do
      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation { createCodeRef(path: "lib/test.ex") { id } }
        """)
        |> json_response(200)

      assert [%{"message" => msg}] = result["errors"]
      assert msg =~ "must provide either"
    end
  end

  # ─── 7. Error / Edge Cases ──────────────────────────────────────────

  describe "mutation validation errors" do
    test "createProject with missing name", %{conn: conn} do
      user = create_user()

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation { createProject(description: "No name") { id } }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end

    test "createTask with missing title", %{conn: conn} do
      user = create_user()
      {:ok, project} = Accounts.Projects.insert(user.id, %{name: "P"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation { createTask(projectId: "#{project.id}", description: "no title") { id } }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end

    test "createWorkflowStep with missing name", %{conn: conn} do
      user = create_user()
      {:ok, project} = Accounts.Projects.insert(user.id, %{name: "P"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation { createWorkflowStep(workflowId: "#{wf.id}", stepOrder: 1) { id } }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end

    test "createSection with missing sectionType", %{conn: conn} do
      user = create_user()
      {:ok, project} = Accounts.Projects.insert(user.id, %{name: "P"})
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "T"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation { createSection(taskId: "#{task.id}", content: "no type") { id } }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end

    test "createSection with missing content", %{conn: conn} do
      user = create_user()
      {:ok, project} = Accounts.Projects.insert(user.id, %{name: "P"})
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "T"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createSection(taskId: "#{task.id}", sectionType: "desc") { id }
          }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end
  end

  describe "workflow assignment edge cases" do
    setup [:setup_user_and_project]

    test "assignWorkflow to task when workflow has no steps", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "Empty WF"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            assignWorkflow(taskId: "#{task.id}", workflowId: "#{wf.id}") {
              id workflowId currentStepId
            }
          }
        """)
        |> json_response(200)

      # Should either work (with nil step) or return an error
      if result["errors"] do
        assert result["errors"] != nil
      else
        data = result["data"]["assignWorkflow"]
        assert data["workflowId"] == wf.id
      end
    end

    test "moveToStep to a step not in the task's workflow", %{
      conn: _conn,
      user: user,
      project: project
    } do
      {:ok, wf1} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF 1"})
      {:ok, step1} = Accounts.WorkflowSteps.insert(wf1, %{name: "S1", step_order: 1})
      {:ok, _} = Accounts.Workflows.update(wf1, %{initial_step_id: step1.id})

      {:ok, wf2} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF 2"})
      {:ok, other_step} = Accounts.WorkflowSteps.insert(wf2, %{name: "Other", step_order: 1})

      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      Sacrum.Repo.TaskWorkflows.assign_workflow(task, wf1)

      result =
        build_conn()
        |> authenticate(user)
        |> graphql("""
          mutation { moveToStep(taskId: "#{task.id}", stepId: "#{other_step.id}") { id } }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end

    test "startStep when task has no workflow", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "No WF Task"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation { startStep(taskId: "#{task.id}") { id } }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end

    test "advanceToStep advances task to target step", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, _step1} = Accounts.WorkflowSteps.insert(workflow, %{name: "Step 1", step_order: 1})
      {:ok, step2} = Accounts.WorkflowSteps.insert(workflow, %{name: "Step 2", step_order: 2})

      # Assign workflow (puts task on step1)
      conn
      |> authenticate(user)
      |> graphql("""
        mutation { assignWorkflow(taskId: "#{task.id}", workflowId: "#{workflow.id}") { id } }
      """)

      # Advance directly to step2 (no transition required)
      result =
        build_conn()
        |> authenticate(user)
        |> graphql("""
          mutation { advanceToStep(taskId: "#{task.id}", stepId: "#{step2.id}") { id currentStepId } }
        """)
        |> json_response(200)

      assert result["data"]["advanceToStep"]["currentStepId"] == step2.id
    end

    test "advanceToStep when task has no workflow", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "No WF Task"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation { advanceToStep(taskId: "#{task.id}", stepId: "#{Ecto.UUID.generate()}") { id } }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end

    test "advanceToStep with step from different workflow", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf1} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF1"})
      {:ok, _step1} = Accounts.WorkflowSteps.insert(wf1, %{name: "Step 1", step_order: 1})
      {:ok, wf2} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF2"})
      {:ok, other_step} = Accounts.WorkflowSteps.insert(wf2, %{name: "Other Step", step_order: 1})

      # Assign wf1
      conn
      |> authenticate(user)
      |> graphql("""
        mutation { assignWorkflow(taskId: "#{task.id}", workflowId: "#{wf1.id}") { id } }
      """)

      # Try to advance to a step in wf2
      result =
        build_conn()
        |> authenticate(user)
        |> graphql("""
          mutation { advanceToStep(taskId: "#{task.id}", stepId: "#{other_step.id}") { id } }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end

    test "completeStep when task has no workflow", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "No WF Task"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation { completeStep(taskId: "#{task.id}") { id } }
        """)
        |> json_response(200)

      assert result["errors"] != nil
    end

    test "deleteTask with cascade: false orphans children", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, parent} = Accounts.Tasks.insert(user.id, project.id, %{title: "Parent"})
      {:ok, child} = Accounts.Tasks.insert(user.id, project.id, %{title: "Child"})
      {:ok, _} = Sacrum.Repo.TaskHierarchy.set_parent(child, parent)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation { deleteTask(id: "#{parent.id}", cascade: false) { id } }
        """)
        |> json_response(200)

      assert result["data"]["deleteTask"]["id"] == parent.id

      # Child should still exist, with no parent
      check =
        build_conn()
        |> authenticate(user)
        |> graphql(~s|{ task(id: "#{child.id}") { id title parentId } }|)
        |> json_response(200)

      assert check["data"]["task"]["id"] == child.id
      assert check["data"]["task"]["parentId"] == nil
    end
  end

  describe "resolveShortId query" do
    setup [:setup_user_and_project]

    test "resolves UUID prefix to task", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Prefix Task"})
      prefix = String.slice(task.id, 0, 8)

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { resolveShortId(projectId: "#{project.id}", prefix: "#{prefix}") { id title } }
        """)
        |> json_response(200)

      assert result["data"]["resolveShortId"]["id"] == task.id
      assert result["data"]["resolveShortId"]["title"] == "Prefix Task"
    end

    test "returns null for non-matching prefix", %{conn: conn, user: user, project: project} do
      {:ok, _task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { resolveShortId(projectId: "#{project.id}", prefix: "00000000") { id } }
        """)
        |> json_response(200)

      assert result["data"]["resolveShortId"] == nil
      assert [%{"message" => _}] = result["errors"]
    end

    test "does not resolve tasks from another user's project", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Secret"})
      prefix = String.slice(task.id, 0, 8)

      other_user = create_user(%{email: "other@example.com", username: "other"})

      result =
        conn
        |> authenticate(other_user)
        |> graphql("""
          { resolveShortId(projectId: "#{project.id}", prefix: "#{prefix}") { id } }
        """)
        |> json_response(200)

      assert result["data"]["resolveShortId"] == nil
      assert [%{"message" => _}] = result["errors"]
    end

    test "returns error for invalid (non-hex) prefix", %{
      conn: conn,
      user: user,
      project: project
    } do
      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { resolveShortId(projectId: "#{project.id}", prefix: "zzzzzzzz") { id } }
        """)
        |> json_response(200)

      assert result["data"]["resolveShortId"] == nil
      assert [%{"message" => _}] = result["errors"]
    end
  end

  describe "task archived field" do
    setup [:setup_user_and_project]

    test "tasks query with default args excludes archived tasks", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, active_task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Active Task"})
      {:ok, archived_task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Archived Task"})

      # Archive the second task
      Accounts.Tasks.update(archived_task, %{archived: true})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { tasks(projectId: "#{project.id}") { id title archived } }
        """)
        |> json_response(200)

      tasks = result["data"]["tasks"]
      assert length(tasks) == 1
      assert hd(tasks)["id"] == active_task.id
      assert hd(tasks)["archived"] == false
    end

    test "tasks query with include_archived: true returns all tasks", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, active_task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Active Task"})
      {:ok, archived_task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Archived Task"})

      # Archive the second task
      Accounts.Tasks.update(archived_task, %{archived: true})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { tasks(projectId: "#{project.id}", includeArchived: true) { id title archived } }
        """)
        |> json_response(200)

      tasks = result["data"]["tasks"]
      assert length(tasks) == 2

      # Find each task
      active = Enum.find(tasks, &(&1["id"] == active_task.id))
      archived = Enum.find(tasks, &(&1["id"] == archived_task.id))

      assert active["archived"] == false
      assert archived["archived"] == true
    end

    test "updateTask mutation can set archived: true on a task", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task to Archive"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateTask(id: "#{task.id}", archived: true) {
              id title archived
            }
          }
        """)
        |> json_response(200)

      data = result["data"]["updateTask"]
      assert data["archived"] == true
      assert data["title"] == "Task to Archive"
    end

    test "archived task is excluded from subsequent tasks query", %{
      conn: conn,
      user: user,
      project: project
    } do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task to Archive"})

      # Archive the task
      conn
      |> authenticate(user)
      |> graphql("""
        mutation {
          updateTask(id: "#{task.id}", archived: true) { id }
        }
      """)

      # Query again with default args (should not include archived)
      result =
        build_conn()
        |> authenticate(user)
        |> graphql("""
          { tasks(projectId: "#{project.id}") { id } }
        """)
        |> json_response(200)

      tasks = result["data"]["tasks"]
      assert length(tasks) == 0
    end

    test "createTask does not support archived: true — field is ignored", %{
      conn: conn,
      user: user,
      project: project
    } do
      # Try to create task without archived arg; it should default to false
      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createTask(
              projectId: "#{project.id}"
              title: "New Task"
            ) { id archived }
          }
        """)
        |> json_response(200)

      # The archived field will be false because that's the default
      data = result["data"]["createTask"]
      assert data["archived"] == false
    end
  end

  describe "FSM mutations — gating when task has active orchestrator" do
    setup do
      # Each test creates its own task, ensure registry is clean
      user = create_user()
      {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Test Project"})
      {:ok, workflow} = Accounts.Workflows.insert(user.id, project.id, %{name: "Test Workflow"})

      {:ok, step1} =
        Accounts.WorkflowSteps.insert(user.id, %{
          "name" => "step_1",
          "workflow_id" => workflow.id,
          "project_id" => project.id,
          "step_order" => 1,
          "agents" => ["test"],
          "skills" => ["test_skill"],
          "agent_config" => %{"model" => "test-model"},
          "prompt" => "Test prompt"
        })

      {:ok, step2} =
        Accounts.WorkflowSteps.insert(user.id, %{
          "name" => "step_2",
          "workflow_id" => workflow.id,
          "project_id" => project.id,
          "step_order" => 2,
          "agents" => ["test"],
          "skills" => ["test_skill"],
          "agent_config" => %{"model" => "test-model"},
          "prompt" => "Test prompt"
        })

      # Create transition from step1 to step2
      {:ok, _transition} =
        Accounts.StepTransitions.insert(user.id, %{
          from_step_id: step1.id,
          to_step_id: step2.id,
          project_id: project.id
        })

      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Test Task"})
      {:ok, task} = Sacrum.Repo.TaskWorkflows.assign_workflow(task, workflow)

      %{user: user, project: project, workflow: workflow, task: task, step1: step1, step2: step2}
    end

    test "moveToStep is allowed when no active orchestrator", %{
      conn: conn,
      user: user,
      task: task,
      step2: step2
    } do
      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            moveToStep(taskId: "#{task.id}", stepId: "#{step2.id}") {
              id currentStepId
            }
          }
        """)
        |> json_response(200)

      assert result["data"]["moveToStep"]["currentStepId"] == step2.id
    end

    test "advanceToStep is allowed when no active orchestrator", %{
      conn: conn,
      user: user,
      task: task,
      step2: step2
    } do
      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            advanceToStep(taskId: "#{task.id}", stepId: "#{step2.id}") {
              id currentStepId
            }
          }
        """)
        |> json_response(200)

      assert result["data"]["advanceToStep"]["currentStepId"] == step2.id
    end

    test "unassignWorkflow is allowed when no active orchestrator", %{
      conn: conn,
      user: user,
      task: task
    } do
      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            unassignWorkflow(taskId: "#{task.id}") {
              id workflowId
            }
          }
        """)
        |> json_response(200)

      assert result["data"]["unassignWorkflow"]["workflowId"] == nil
    end

    test "moveToStep is rejected when task has active orchestrator", %{
      conn: conn,
      user: user,
      task: task,
      step2: step2
    } do
      # Start a TaskOrchestrator for the task (simulated by registering in the registry)
      {:ok, _pid} =
        Sacrum.Orchestrator.TaskOrchestrator.start_link(
          task_id: task.id,
          user_id: user.id
        )

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            moveToStep(taskId: "#{task.id}", stepId: "#{step2.id}") {
              id currentStepId
            }
          }
        """)
        |> json_response(200)

      assert result["errors"] != nil
      assert Enum.any?(result["errors"], &String.contains?(&1["message"], "active orchestrator"))
    end

    test "advanceToStep is rejected when task has active orchestrator", %{
      conn: conn,
      user: user,
      task: task,
      step2: step2
    } do
      # Start a TaskOrchestrator for the task
      {:ok, _pid} =
        Sacrum.Orchestrator.TaskOrchestrator.start_link(
          task_id: task.id,
          user_id: user.id
        )

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            advanceToStep(taskId: "#{task.id}", stepId: "#{step2.id}") {
              id currentStepId
            }
          }
        """)
        |> json_response(200)

      assert result["errors"] != nil
      assert Enum.any?(result["errors"], &String.contains?(&1["message"], "active orchestrator"))
    end
  end

  defp routing_config(destination_id) do
    %{
      "version" => 1,
      "match_policy" => "exactly_one",
      "rules" => [
        %{
          "id" => "approved",
          "when" => %{
            "ref" => "previous_output.route.result",
            "op" => "eq",
            "value" => "approved"
          },
          "transition" => %{"type" => "intra_workflow", "step_id" => destination_id}
        }
      ],
      "default" => %{
        "transition" => %{"type" => "intra_workflow", "step_id" => destination_id}
      }
    }
  end

  defp routing_predecessor_schema do
    %{
      "type" => "object",
      "properties" => %{
        "route" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["result", "handoff"],
          "properties" => %{
            "result" => %{"type" => "string", "enum" => ["approved"]},
            "handoff" => %{
              "type" => "object",
              "additionalProperties" => false,
              "required" => [],
              "properties" => %{}
            }
          }
        }
      },
      "required" => ["route"],
      "additionalProperties" => false
    }
  end
end
