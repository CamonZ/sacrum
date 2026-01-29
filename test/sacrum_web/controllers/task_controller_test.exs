defmodule SacrumWeb.TaskControllerTest do
  use SacrumWeb.ConnCase, async: true

  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.TaskDependencies
  alias Sacrum.Repo.TaskHierarchy
  alias Sacrum.Auth

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp create_user(attrs \\ @valid_user_attrs) do
    {:ok, user} = Users.insert(attrs)
    user
  end

  defp authenticate(conn, user) do
    {:ok, token, _api_token} = Auth.create_api_token(user)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp setup_authenticated(%{conn: conn}) do
    user = create_user()
    conn = authenticate(conn, user)
    {:ok, project} = Projects.insert(user, %{name: "Test Project"})
    %{conn: conn, user: user, project: project}
  end

  describe "unauthenticated requests" do
    test "returns 401 without auth header", %{conn: conn} do
      conn = get(conn, ~p"/api/tasks?project_id=#{Ecto.UUID.generate()}")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/tasks" do
    setup :setup_authenticated

    test "returns 200 with task list", %{conn: conn, project: project} do
      {:ok, _} = Tasks.insert(project, %{title: "Task 1"})
      {:ok, _} = Tasks.insert(project, %{title: "Task 2"})

      conn = get(conn, ~p"/api/tasks?project_id=#{project.id}")
      assert %{"data" => tasks} = json_response(conn, 200)
      assert length(tasks) == 2
    end

    test "returns empty list for project with no tasks", %{conn: conn, project: project} do
      conn = get(conn, ~p"/api/tasks?project_id=#{project.id}")
      assert %{"data" => []} = json_response(conn, 200)
    end
  end

  describe "GET /api/tasks/:id" do
    setup :setup_authenticated

    test "returns 200 with task JSON", %{conn: conn, project: project} do
      {:ok, task} = Tasks.insert(project, %{title: "My Task"})

      conn = get(conn, ~p"/api/tasks/#{task.id}")

      assert %{
               "data" => %{
                 "id" => id,
                 "title" => "My Task",
                 "short_id" => short_id
               }
             } = json_response(conn, 200)

      assert id == task.id
      assert short_id =~ ~r/^x[a-f0-9]{6}$/
    end

    test "returns 404 for nonexistent task", %{conn: conn} do
      conn = get(conn, ~p"/api/tasks/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end
  end

  describe "POST /api/tasks" do
    setup :setup_authenticated

    test "returns 201 with valid params", %{conn: conn, project: project} do
      conn =
        post(conn, ~p"/api/tasks", %{
          project_id: project.id,
          title: "New Task",
          description: "A description",
          level: "ticket"
        })

      assert %{
               "data" => %{
                 "title" => "New Task",
                 "description" => "A description",
                 "level" => "ticket",
                 "short_id" => _
               }
             } = json_response(conn, 201)
    end

    test "returns 422 with missing title", %{conn: conn, project: project} do
      conn = post(conn, ~p"/api/tasks", %{project_id: project.id})
      assert %{"errors" => %{"title" => _}} = json_response(conn, 422)
    end
  end

  describe "PATCH /api/tasks/:id" do
    setup :setup_authenticated

    test "updates and returns 200", %{conn: conn, project: project} do
      {:ok, task} = Tasks.insert(project, %{title: "Original"})

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}", %{
          title: "Updated",
          description: "New desc"
        })

      assert %{
               "data" => %{
                 "title" => "Updated",
                 "description" => "New desc"
               }
             } = json_response(conn, 200)
    end
  end

  describe "DELETE /api/tasks/:id" do
    setup :setup_authenticated

    test "returns 204", %{conn: conn, project: project} do
      {:ok, task} = Tasks.insert(project, %{title: "To Delete"})
      conn = delete(conn, ~p"/api/tasks/#{task.id}")
      assert response(conn, 204)
    end
  end

  describe "POST /api/tasks with inline sections" do
    setup :setup_authenticated

    test "creates task with sections array", %{conn: conn, project: project} do
      conn =
        post(conn, ~p"/api/tasks", %{
          project_id: project.id,
          title: "Task with sections",
          sections: [
            %{section_type: "goal", content: "Build the thing", section_order: 1},
            %{section_type: "step", content: "Step one", section_order: 2}
          ]
        })

      assert %{
               "data" => %{
                 "title" => "Task with sections",
                 "sections" => sections
               }
             } = json_response(conn, 201)

      assert length(sections) == 2
      assert Enum.any?(sections, &(&1["section_type"] == "goal"))
      assert Enum.any?(sections, &(&1["section_type"] == "step"))
    end

    test "creates task without sections (optional)", %{conn: conn, project: project} do
      conn =
        post(conn, ~p"/api/tasks", %{
          project_id: project.id,
          title: "No sections"
        })

      assert %{"data" => %{"sections" => []}} = json_response(conn, 201)
    end

    test "returns 422 when section missing required fields", %{conn: conn, project: project} do
      conn =
        post(conn, ~p"/api/tasks", %{
          project_id: project.id,
          title: "Bad sections",
          sections: [%{content: "missing section_type"}]
        })

      assert json_response(conn, 422)
    end
  end

  describe "PATCH /api/tasks/:id with inline sections" do
    setup :setup_authenticated

    test "adds new sections to task", %{conn: conn, project: project} do
      {:ok, task} = Tasks.insert(project, %{title: "Task"})

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}", %{
          title: "Task",
          sections: [
            %{section_type: "goal", content: "New goal", section_order: 1}
          ]
        })

      assert %{"data" => %{"sections" => [section]}} = json_response(conn, 200)
      assert section["section_type"] == "goal"
      assert section["content"] == "New goal"
    end

    test "updates existing sections by id", %{conn: conn, project: project} do
      {:ok, task} =
        Tasks.insert(project, %{
          "title" => "Task",
          "sections" => [%{"section_type" => "goal", "content" => "Original"}]
        })

      section_id = hd(task.sections).id

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}", %{
          title: "Task",
          sections: [
            %{id: section_id, section_type: "goal", content: "Updated"}
          ]
        })

      assert %{"data" => %{"sections" => [section]}} = json_response(conn, 200)
      assert section["id"] == section_id
      assert section["content"] == "Updated"
    end

    test "removes sections not in the list", %{conn: conn, project: project} do
      {:ok, task} =
        Tasks.insert(project, %{
          "title" => "Task",
          "sections" => [
            %{"section_type" => "goal", "content" => "Keep"},
            %{"section_type" => "step", "content" => "Remove"}
          ]
        })

      keep_section = Enum.find(task.sections, &(&1.section_type == "goal"))

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}", %{
          title: "Task",
          sections: [
            %{id: keep_section.id, section_type: "goal", content: "Keep"}
          ]
        })

      assert %{"data" => %{"sections" => sections}} = json_response(conn, 200)
      assert length(sections) == 1
      assert hd(sections)["content"] == "Keep"
    end

    test "omitting sections param does not change sections", %{conn: conn, project: project} do
      {:ok, task} =
        Tasks.insert(project, %{
          "title" => "Task",
          "sections" => [%{"section_type" => "goal", "content" => "Stays"}]
        })

      conn = patch(conn, ~p"/api/tasks/#{task.id}", %{title: "Updated title"})

      assert %{"data" => %{"title" => "Updated title", "sections" => [section]}} =
               json_response(conn, 200)

      assert section["content"] == "Stays"
    end

    test "returns 422 for section id not belonging to this task", %{
      conn: conn,
      project: project
    } do
      {:ok, task1} =
        Tasks.insert(project, %{
          "title" => "Task 1",
          "sections" => [%{"section_type" => "goal", "content" => "Task 1 section"}]
        })

      {:ok, task2} = Tasks.insert(project, %{title: "Task 2"})
      foreign_section_id = hd(task1.sections).id

      conn =
        patch(conn, ~p"/api/tasks/#{task2.id}", %{
          title: "Task 2",
          sections: [
            %{id: foreign_section_id, section_type: "goal", content: "Stolen"}
          ]
        })

      assert json_response(conn, 422)
    end

    test "returns 422 when section missing required fields", %{conn: conn, project: project} do
      {:ok, task} = Tasks.insert(project, %{title: "Task"})

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}", %{
          title: "Task",
          sections: [%{content: "missing section_type"}]
        })

      assert json_response(conn, 422)
    end
  end

  describe "section cascade deletion" do
    setup :setup_authenticated

    test "deleting a section via sync also deletes its code_refs", %{
      conn: conn,
      project: project
    } do
      {:ok, task} =
        Tasks.insert(project, %{
          "title" => "Task",
          "sections" => [%{"section_type" => "goal", "content" => "Has refs"}]
        })

      section = hd(task.sections)

      # Create a code_ref for this section
      {:ok, _ref} =
        Sacrum.Repo.CodeRefs.insert_for_section(section, %{
          path: "lib/foo.ex",
          line_start: 1,
          line_end: 10
        })

      # Now update the task with empty sections, removing the section
      conn =
        patch(conn, ~p"/api/tasks/#{task.id}", %{
          title: "Task",
          sections: []
        })

      assert %{"data" => %{"sections" => []}} = json_response(conn, 200)

      # Verify code_ref was cascade deleted
      assert Sacrum.Repo.all(Sacrum.Repo.Schemas.CodeRef) == []
    end
  end

  describe "GET /api/tasks filters" do
    setup :setup_authenticated

    test "filters by status (workflow step name)", %{conn: conn, project: project} do
      {:ok, workflow} = Sacrum.Repo.Workflows.insert(project, %{name: "Test Workflow"})

      {:ok, step} =
        Sacrum.Repo.WorkflowSteps.insert(workflow.id, %{name: "in_progress", step_order: 1})

      {:ok, _} = Sacrum.Repo.Workflows.update(workflow, %{initial_step_id: step.id})

      {:ok, task1} = Tasks.insert(project, %{title: "Task with workflow"})
      {:ok, _task1} = Sacrum.Repo.TaskWorkflows.assign_workflow(task1, workflow)
      {:ok, _task2} = Tasks.insert(project, %{title: "Task without workflow"})

      conn = get(conn, ~p"/api/tasks?project_id=#{project.id}&status=in_progress")
      assert %{"data" => tasks} = json_response(conn, 200)
      assert length(tasks) == 1
      assert hd(tasks)["title"] == "Task with workflow"
    end

    test "filters by tags", %{conn: conn, project: project} do
      {:ok, _} = Tasks.insert(project, %{title: "Tagged", tags: ["backend", "urgent"]})
      {:ok, _} = Tasks.insert(project, %{title: "Other", tags: ["frontend"]})
      {:ok, _} = Tasks.insert(project, %{title: "No tags"})

      conn = get(conn, ~p"/api/tasks?project_id=#{project.id}&tags=backend")
      assert %{"data" => tasks} = json_response(conn, 200)
      assert length(tasks) == 1
      assert hd(tasks)["title"] == "Tagged"
    end

    test "filters by root_only", %{conn: conn, project: project} do
      {:ok, parent} = Tasks.insert(project, %{title: "Parent"})
      {:ok, child} = Tasks.insert(project, %{title: "Child"})
      {:ok, _} = Sacrum.Repo.TaskHierarchy.set_parent(child, parent)

      conn = get(conn, ~p"/api/tasks?project_id=#{project.id}&root_only=true")
      assert %{"data" => tasks} = json_response(conn, 200)
      assert length(tasks) == 1
      assert hd(tasks)["title"] == "Parent"
    end

    test "filters by workflow_id", %{conn: conn, project: project} do
      {:ok, workflow} = Sacrum.Repo.Workflows.insert(project, %{name: "WF1"})

      {:ok, step} =
        Sacrum.Repo.WorkflowSteps.insert(workflow.id, %{name: "start", step_order: 1})

      {:ok, _} = Sacrum.Repo.Workflows.update(workflow, %{initial_step_id: step.id})

      {:ok, task1} = Tasks.insert(project, %{title: "In workflow"})
      {:ok, _} = Sacrum.Repo.TaskWorkflows.assign_workflow(task1, workflow)
      {:ok, _} = Tasks.insert(project, %{title: "Not in workflow"})

      conn = get(conn, ~p"/api/tasks?project_id=#{project.id}&workflow_id=#{workflow.id}")
      assert %{"data" => tasks} = json_response(conn, 200)
      assert length(tasks) == 1
      assert hd(tasks)["title"] == "In workflow"
    end

    test "combines filters correctly", %{conn: conn, project: project} do
      {:ok, parent} = Tasks.insert(project, %{title: "Root tagged", tags: ["backend"]})
      {:ok, child} = Tasks.insert(project, %{title: "Child tagged", tags: ["backend"]})
      {:ok, _} = Sacrum.Repo.TaskHierarchy.set_parent(child, parent)
      {:ok, _} = Tasks.insert(project, %{title: "Root untagged"})

      conn =
        get(conn, ~p"/api/tasks?project_id=#{project.id}&root_only=true&tags=backend")

      assert %{"data" => tasks} = json_response(conn, 200)
      assert length(tasks) == 1
      assert hd(tasks)["title"] == "Root tagged"
    end

    test "empty filter values are ignored", %{conn: conn, project: project} do
      {:ok, _} = Tasks.insert(project, %{title: "Task 1"})

      conn =
        get(
          conn,
          ~p"/api/tasks?project_id=#{project.id}&status=&tags=&root_only=&workflow_id="
        )

      assert %{"data" => tasks} = json_response(conn, 200)
      assert length(tasks) == 1
    end
  end

  describe "GET /api/tasks/ready" do
    setup :setup_authenticated

    test "returns root tasks with no incomplete blockers", %{conn: conn, project: project} do
      {:ok, root} = Tasks.insert(project, %{title: "Root Task"})
      {:ok, child} = Tasks.insert(project, %{title: "Child Task"})
      {:ok, _} = Sacrum.Repo.TaskHierarchy.set_parent(child, root)

      conn = get(conn, ~p"/api/tasks/ready?project_id=#{project.id}")
      assert %{"data" => tasks} = json_response(conn, 200)
      assert length(tasks) == 1
      assert hd(tasks)["title"] == "Root Task"
    end

    test "excludes tasks with incomplete blockers", %{conn: conn, project: project} do
      {:ok, blocker} = Tasks.insert(project, %{title: "Blocker"})
      {:ok, blocked} = Tasks.insert(project, %{title: "Blocked"})
      {:ok, _} = Sacrum.Repo.TaskDependencies.add_dependency(blocked, blocker)

      conn = get(conn, ~p"/api/tasks/ready?project_id=#{project.id}")
      assert %{"data" => tasks} = json_response(conn, 200)
      titles = Enum.map(tasks, & &1["title"])
      assert "Blocker" in titles
      refute "Blocked" in titles
    end

    test "includes tasks whose blockers are all completed", %{conn: conn, project: project} do
      {:ok, blocker} = Tasks.insert(project, %{title: "Done Blocker"})
      {:ok, _} = Tasks.update(blocker, %{completed_at: DateTime.utc_now()})
      {:ok, task} = Tasks.insert(project, %{title: "Unblocked"})
      {:ok, _} = Sacrum.Repo.TaskDependencies.add_dependency(task, blocker)

      conn = get(conn, ~p"/api/tasks/ready?project_id=#{project.id}")
      assert %{"data" => tasks} = json_response(conn, 200)
      titles = Enum.map(tasks, & &1["title"])
      assert "Unblocked" in titles
    end

    test "returns 401 without auth token", %{conn: _conn} do
      conn = build_conn()
      conn = get(conn, ~p"/api/tasks/ready?project_id=#{Ecto.UUID.generate()}")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/tasks/:task_id/tree" do
    setup :setup_authenticated

    test "returns tree with root task and nested children", %{conn: conn, project: project} do
      {:ok, root} = Tasks.insert(project, %{title: "Root"})
      {:ok, child} = Tasks.insert(project, %{title: "Child"})
      {:ok, grandchild} = Tasks.insert(project, %{title: "Grandchild"})
      {:ok, _} = Sacrum.Repo.TaskHierarchy.set_parent(child, root)
      {:ok, _} = Sacrum.Repo.TaskHierarchy.set_parent(grandchild, child)

      conn = get(conn, ~p"/api/tasks/#{root.id}/tree")
      assert %{"data" => tree} = json_response(conn, 200)
      assert tree["title"] == "Root"
      assert length(tree["children"]) == 1
      child_node = hd(tree["children"])
      assert child_node["title"] == "Child"
      assert length(child_node["children"]) == 1
      assert hd(child_node["children"])["title"] == "Grandchild"
    end

    test "leaf task has empty children array", %{conn: conn, project: project} do
      {:ok, leaf} = Tasks.insert(project, %{title: "Leaf"})

      conn = get(conn, ~p"/api/tasks/#{leaf.id}/tree")
      assert %{"data" => tree} = json_response(conn, 200)
      assert tree["title"] == "Leaf"
      assert tree["children"] == []
    end

    test "returns 404 for nonexistent task", %{conn: conn} do
      conn = get(conn, ~p"/api/tasks/#{Ecto.UUID.generate()}/tree")
      assert json_response(conn, 404)
    end
  end

  describe "returns 404 for another user's task" do
    test "GET /api/tasks/:id", %{conn: _conn} do
      {:ok, other_user} =
        Sacrum.Repo.Users.insert(%{
          email: "other@example.com",
          username: "other",
          password: "password123"
        })

      {:ok, other_project} = Sacrum.Repo.Projects.insert(other_user, %{name: "Other"})
      {:ok, other_task} = Tasks.insert(other_project, %{title: "Other Task"})

      {:ok, user} =
        Sacrum.Repo.Users.insert(%{
          email: "me@example.com",
          username: "meuser",
          password: "password123"
        })

      {:ok, token, _} = Sacrum.Auth.create_api_token(user)
      conn = build_conn() |> put_req_header("authorization", "Bearer #{token}")

      conn = get(conn, ~p"/api/tasks/#{other_task.id}")
      assert json_response(conn, 404)
    end
  end

  describe "PATCH with nested parent_id and depends_on_ids" do
    setup :setup_authenticated

    test "sets parent_id via task update", %{conn: conn, project: project} do
      {:ok, parent} = Tasks.insert(project, %{title: "Parent"})
      {:ok, child} = Tasks.insert(project, %{title: "Child"})

      conn =
        patch(conn, ~p"/api/tasks/#{child.id}", %{
          title: "Child",
          parent_id: parent.id
        })

      assert %{"data" => %{"parent_id" => parent_id}} = json_response(conn, 200)
      assert parent_id == parent.id
    end

    test "null parent_id removes parent", %{conn: conn, project: project} do
      {:ok, parent} = Tasks.insert(project, %{title: "Parent"})
      {:ok, child} = Tasks.insert(project, %{title: "Child"})
      {:ok, _} = TaskHierarchy.set_parent(child, parent)

      conn =
        patch(conn, ~p"/api/tasks/#{child.id}", %{
          title: "Child",
          parent_id: nil
        })

      assert %{"data" => %{"parent_id" => nil}} = json_response(conn, 200)
      assert {:error, :not_found} = TaskHierarchy.get_parent(child)
    end

    test "null parent_id succeeds when no parent exists", %{conn: conn, project: project} do
      {:ok, task} = Tasks.insert(project, %{title: "Orphan"})

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}", %{
          title: "Orphan",
          parent_id: nil
        })

      assert json_response(conn, 200)
    end

    test "sets depends_on_ids via task update", %{conn: conn, project: project} do
      {:ok, dep1} = Tasks.insert(project, %{title: "Dep 1"})
      {:ok, dep2} = Tasks.insert(project, %{title: "Dep 2"})
      {:ok, task} = Tasks.insert(project, %{title: "Task"})

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}", %{
          title: "Task",
          depends_on_ids: [dep1.id, dep2.id]
        })

      assert %{"data" => %{"dependency_ids" => dep_ids}} = json_response(conn, 200)
      assert length(dep_ids) == 2
    end

    test "returns 422 for self dependency", %{conn: conn, project: project} do
      {:ok, task} = Tasks.insert(project, %{title: "Task"})

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}", %{
          title: "Task",
          depends_on_ids: [task.id]
        })

      assert %{"errors" => _} = json_response(conn, 422)
    end

    test "returns 422 for circular dependency", %{conn: conn, project: project} do
      {:ok, a} = Tasks.insert(project, %{title: "A"})
      {:ok, b} = Tasks.insert(project, %{title: "B"})
      {:ok, _} = TaskDependencies.add_dependency(b, a)

      conn =
        patch(conn, ~p"/api/tasks/#{a.id}", %{
          title: "A",
          depends_on_ids: [b.id]
        })

      assert %{"errors" => _} = json_response(conn, 422)
    end

    test "returns 422 for cross-project dependency", %{conn: conn, user: user, project: project} do
      {:ok, other_project} = Projects.insert(user, %{name: "Other Project"})
      {:ok, task} = Tasks.insert(project, %{title: "Task"})
      {:ok, other_task} = Tasks.insert(other_project, %{title: "Other"})

      conn =
        patch(conn, ~p"/api/tasks/#{task.id}", %{
          title: "Task",
          depends_on_ids: [other_task.id]
        })

      assert %{"errors" => _} = json_response(conn, 422)
    end
  end

  describe "JSON response includes parent_id and dependency_ids" do
    setup :setup_authenticated

    test "show includes parent_id and dependency_ids", %{conn: conn, project: project} do
      {:ok, task} = Tasks.insert(project, %{title: "Task"})

      conn = get(conn, ~p"/api/tasks/#{task.id}")
      assert %{"data" => data} = json_response(conn, 200)
      assert Map.has_key?(data, "parent_id")
      assert Map.has_key?(data, "dependency_ids")
      assert data["parent_id"] == nil
      assert data["dependency_ids"] == []
    end

    test "index includes parent_id and dependency_ids", %{conn: conn, project: project} do
      {:ok, _} = Tasks.insert(project, %{title: "Task"})

      conn = get(conn, ~p"/api/tasks?project_id=#{project.id}")
      assert %{"data" => [data]} = json_response(conn, 200)
      assert Map.has_key?(data, "parent_id")
      assert Map.has_key?(data, "dependency_ids")
    end
  end

  describe "GET /api/tasks/:task_id/blockers" do
    setup :setup_authenticated

    test "returns transitive blockers", %{conn: conn, project: project} do
      {:ok, task} = Tasks.insert(project, %{title: "Task A"})
      {:ok, blocker1} = Tasks.insert(project, %{title: "Blocker 1"})
      {:ok, blocker2} = Tasks.insert(project, %{title: "Blocker 2"})
      {:ok, _} = TaskDependencies.add_dependency(task, blocker1)
      {:ok, _} = TaskDependencies.add_dependency(blocker1, blocker2)

      conn = get(conn, ~p"/api/tasks/#{task.id}/blockers")

      assert %{"data" => blockers} = json_response(conn, 200)
      assert length(blockers) == 2
    end
  end

  describe "GET /api/tasks/:task_id/path" do
    setup :setup_authenticated

    test "returns shortest dependency path", %{conn: conn, project: project} do
      {:ok, a} = Tasks.insert(project, %{title: "A"})
      {:ok, b} = Tasks.insert(project, %{title: "B"})
      {:ok, c} = Tasks.insert(project, %{title: "C"})
      {:ok, _} = TaskDependencies.add_dependency(a, b)
      {:ok, _} = TaskDependencies.add_dependency(b, c)

      conn = get(conn, ~p"/api/tasks/#{a.id}/path?to=#{c.id}")
      assert %{"data" => %{"path" => path}} = json_response(conn, 200)
      assert length(path) == 3
      assert path == [a.id, b.id, c.id]
    end

    test "returns empty path when no dependency path exists", %{conn: conn, project: project} do
      {:ok, a} = Tasks.insert(project, %{title: "A"})
      {:ok, b} = Tasks.insert(project, %{title: "B"})

      conn = get(conn, ~p"/api/tasks/#{a.id}/path?to=#{b.id}")
      assert %{"data" => %{"path" => []}} = json_response(conn, 200)
    end

    test "returns single-element path for direct dependency", %{conn: conn, project: project} do
      {:ok, a} = Tasks.insert(project, %{title: "A"})
      {:ok, b} = Tasks.insert(project, %{title: "B"})
      {:ok, _} = TaskDependencies.add_dependency(a, b)

      conn = get(conn, ~p"/api/tasks/#{a.id}/path?to=#{b.id}")
      assert %{"data" => %{"path" => path}} = json_response(conn, 200)
      assert path == [a.id, b.id]
    end

    test "returns 404 if target task does not exist", %{conn: conn, project: project} do
      {:ok, a} = Tasks.insert(project, %{title: "A"})

      conn = get(conn, ~p"/api/tasks/#{a.id}/path?to=#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end

    test "returns 422 when to param is missing", %{conn: conn, project: project} do
      {:ok, task} = Tasks.insert(project, %{title: "Task"})
      conn = get(conn, ~p"/api/tasks/#{task.id}/path")
      assert json_response(conn, 422)
    end
  end
end
