defmodule SacrumWeb.TaskControllerTest do
  use SacrumWeb.ConnCase, async: true

  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Tasks
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
      project_id = Ecto.UUID.generate()
      conn = get(conn, ~p"/api/projects/#{project_id}/tasks")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/projects/:project_id/tasks" do
    setup :setup_authenticated

    test "returns 200 with task list", %{conn: conn, project: project} do
      {:ok, _} = Tasks.insert(project, %{title: "Task 1"})
      {:ok, _} = Tasks.insert(project, %{title: "Task 2"})

      conn = get(conn, ~p"/api/projects/#{project.id}/tasks")
      assert %{"data" => tasks} = json_response(conn, 200)
      assert length(tasks) == 2
    end

    test "returns empty list for project with no tasks", %{conn: conn, project: project} do
      conn = get(conn, ~p"/api/projects/#{project.id}/tasks")
      assert %{"data" => []} = json_response(conn, 200)
    end
  end

  describe "GET /api/projects/:project_id/tasks/:id" do
    setup :setup_authenticated

    test "returns 200 with task JSON", %{conn: conn, project: project} do
      {:ok, task} = Tasks.insert(project, %{title: "My Task"})

      conn = get(conn, ~p"/api/projects/#{project.id}/tasks/#{task.id}")

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

    test "returns 404 for nonexistent task", %{conn: conn, project: project} do
      conn = get(conn, ~p"/api/projects/#{project.id}/tasks/#{Ecto.UUID.generate()}")
      assert json_response(conn, 404)
    end
  end

  describe "POST /api/projects/:project_id/tasks" do
    setup :setup_authenticated

    test "returns 201 with valid params", %{conn: conn, project: project} do
      conn =
        post(conn, ~p"/api/projects/#{project.id}/tasks", %{
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
      conn = post(conn, ~p"/api/projects/#{project.id}/tasks", %{})
      assert %{"errors" => %{"title" => _}} = json_response(conn, 422)
    end
  end

  describe "PUT /api/projects/:project_id/tasks/:id" do
    setup :setup_authenticated

    test "updates and returns 200", %{conn: conn, project: project} do
      {:ok, task} = Tasks.insert(project, %{title: "Original"})

      conn =
        put(conn, ~p"/api/projects/#{project.id}/tasks/#{task.id}", %{
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

  describe "DELETE /api/projects/:project_id/tasks/:id" do
    setup :setup_authenticated

    test "returns 204", %{conn: conn, project: project} do
      {:ok, task} = Tasks.insert(project, %{title: "To Delete"})
      conn = delete(conn, ~p"/api/projects/#{project.id}/tasks/#{task.id}")
      assert response(conn, 204)
    end
  end

  describe "GET /api/projects/:project_id/tasks filters" do
    setup :setup_authenticated

    test "filters by status (workflow step name)", %{conn: conn, project: project} do
      # Create a workflow with a step
      {:ok, workflow} = Sacrum.Repo.Workflows.insert(project, %{name: "Test Workflow"})

      {:ok, step} =
        Sacrum.Repo.WorkflowSteps.insert(workflow.id, %{name: "in_progress", step_order: 1})

      {:ok, _} = Sacrum.Repo.Workflows.update(workflow, %{initial_step_id: step.id})

      {:ok, task1} = Tasks.insert(project, %{title: "Task with workflow"})
      {:ok, _task1} = Sacrum.Repo.TaskWorkflows.assign_workflow(task1, workflow)
      {:ok, _task2} = Tasks.insert(project, %{title: "Task without workflow"})

      conn = get(conn, ~p"/api/projects/#{project.id}/tasks?status=in_progress")
      assert %{"data" => tasks} = json_response(conn, 200)
      assert length(tasks) == 1
      assert hd(tasks)["title"] == "Task with workflow"
    end

    test "filters by tags", %{conn: conn, project: project} do
      {:ok, _} = Tasks.insert(project, %{title: "Tagged", tags: ["backend", "urgent"]})
      {:ok, _} = Tasks.insert(project, %{title: "Other", tags: ["frontend"]})
      {:ok, _} = Tasks.insert(project, %{title: "No tags"})

      conn = get(conn, ~p"/api/projects/#{project.id}/tasks?tags=backend")
      assert %{"data" => tasks} = json_response(conn, 200)
      assert length(tasks) == 1
      assert hd(tasks)["title"] == "Tagged"
    end

    test "filters by root_only", %{conn: conn, project: project} do
      {:ok, parent} = Tasks.insert(project, %{title: "Parent"})
      {:ok, child} = Tasks.insert(project, %{title: "Child"})
      {:ok, _} = Sacrum.Repo.TaskHierarchy.set_parent(child, parent)

      conn = get(conn, ~p"/api/projects/#{project.id}/tasks?root_only=true")
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

      conn = get(conn, ~p"/api/projects/#{project.id}/tasks?workflow_id=#{workflow.id}")
      assert %{"data" => tasks} = json_response(conn, 200)
      assert length(tasks) == 1
      assert hd(tasks)["title"] == "In workflow"
    end

    test "combines filters correctly", %{conn: conn, project: project} do
      {:ok, parent} = Tasks.insert(project, %{title: "Root tagged", tags: ["backend"]})
      {:ok, child} = Tasks.insert(project, %{title: "Child tagged", tags: ["backend"]})
      {:ok, _} = Sacrum.Repo.TaskHierarchy.set_parent(child, parent)
      {:ok, _} = Tasks.insert(project, %{title: "Root untagged"})

      conn = get(conn, ~p"/api/projects/#{project.id}/tasks?root_only=true&tags=backend")
      assert %{"data" => tasks} = json_response(conn, 200)
      assert length(tasks) == 1
      assert hd(tasks)["title"] == "Root tagged"
    end

    test "empty filter values are ignored", %{conn: conn, project: project} do
      {:ok, _} = Tasks.insert(project, %{title: "Task 1"})

      conn =
        get(conn, ~p"/api/projects/#{project.id}/tasks?status=&tags=&root_only=&workflow_id=")

      assert %{"data" => tasks} = json_response(conn, 200)
      assert length(tasks) == 1
    end
  end

  describe "GET /api/projects/:project_id/tasks/ready" do
    setup :setup_authenticated

    test "returns root tasks with no incomplete blockers", %{conn: conn, project: project} do
      {:ok, root} = Tasks.insert(project, %{title: "Root Task"})
      {:ok, child} = Tasks.insert(project, %{title: "Child Task"})
      {:ok, _} = Sacrum.Repo.TaskHierarchy.set_parent(child, root)

      conn = get(conn, ~p"/api/projects/#{project.id}/tasks/ready")
      assert %{"data" => tasks} = json_response(conn, 200)
      assert length(tasks) == 1
      assert hd(tasks)["title"] == "Root Task"
    end

    test "excludes tasks with incomplete blockers", %{conn: conn, project: project} do
      {:ok, blocker} = Tasks.insert(project, %{title: "Blocker"})
      {:ok, blocked} = Tasks.insert(project, %{title: "Blocked"})
      {:ok, _} = Sacrum.Repo.TaskDependencies.add_dependency(blocked, blocker)

      conn = get(conn, ~p"/api/projects/#{project.id}/tasks/ready")
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

      conn = get(conn, ~p"/api/projects/#{project.id}/tasks/ready")
      assert %{"data" => tasks} = json_response(conn, 200)
      titles = Enum.map(tasks, & &1["title"])
      assert "Unblocked" in titles
    end

    test "returns 401 without auth token", %{conn: _conn} do
      conn = build_conn()
      conn = get(conn, ~p"/api/projects/#{Ecto.UUID.generate()}/tasks/ready")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/projects/:project_id/tasks/:task_id/tree" do
    setup :setup_authenticated

    test "returns tree with root task and nested children", %{conn: conn, project: project} do
      {:ok, root} = Tasks.insert(project, %{title: "Root"})
      {:ok, child} = Tasks.insert(project, %{title: "Child"})
      {:ok, grandchild} = Tasks.insert(project, %{title: "Grandchild"})
      {:ok, _} = Sacrum.Repo.TaskHierarchy.set_parent(child, root)
      {:ok, _} = Sacrum.Repo.TaskHierarchy.set_parent(grandchild, child)

      conn = get(conn, ~p"/api/projects/#{project.id}/tasks/#{root.id}/tree")
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

      conn = get(conn, ~p"/api/projects/#{project.id}/tasks/#{leaf.id}/tree")
      assert %{"data" => tree} = json_response(conn, 200)
      assert tree["title"] == "Leaf"
      assert tree["children"] == []
    end

    test "returns 404 for nonexistent task", %{conn: conn, project: project} do
      conn =
        get(
          conn,
          ~p"/api/projects/#{project.id}/tasks/#{Ecto.UUID.generate()}/tree"
        )

      assert json_response(conn, 404)
    end
  end

  describe "flat routes - GET/PATCH/DELETE /api/tasks/:id" do
    setup :setup_authenticated

    test "GET /api/tasks/:id returns task", %{conn: conn, project: project} do
      {:ok, task} = Tasks.insert(project, %{title: "Flat Task"})

      conn = get(conn, ~p"/api/tasks/#{task.id}")
      assert %{"data" => %{"title" => "Flat Task"}} = json_response(conn, 200)
    end

    test "PATCH /api/tasks/:id updates task", %{conn: conn, project: project} do
      {:ok, task} = Tasks.insert(project, %{title: "Original"})

      conn = patch(conn, ~p"/api/tasks/#{task.id}", %{title: "Updated"})
      assert %{"data" => %{"title" => "Updated"}} = json_response(conn, 200)
    end

    test "DELETE /api/tasks/:id deletes task", %{conn: conn, project: project} do
      {:ok, task} = Tasks.insert(project, %{title: "To Delete"})

      conn = delete(conn, ~p"/api/tasks/#{task.id}")
      assert response(conn, 204)
    end

    test "returns 404 for another user's task", %{conn: _conn, project: _project} do
      # Create a different user's task
      {:ok, other_user} =
        Sacrum.Repo.Users.insert(%{
          email: "other@example.com",
          username: "other",
          password: "password123"
        })

      {:ok, other_project} = Sacrum.Repo.Projects.insert(other_user, %{name: "Other"})
      {:ok, other_task} = Tasks.insert(other_project, %{title: "Other Task"})

      # Authenticate as the first user
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
        put(conn, ~p"/api/projects/#{project.id}/tasks/#{child.id}", %{
          title: "Child",
          parent_id: parent.id
        })

      assert json_response(conn, 200)

      # Verify parent was set
      {:ok, found_parent} = Sacrum.Repo.TaskHierarchy.get_parent(child)
      assert found_parent.id == parent.id
    end

    test "sets depends_on_ids via task update", %{conn: conn, project: project} do
      {:ok, dep1} = Tasks.insert(project, %{title: "Dep 1"})
      {:ok, dep2} = Tasks.insert(project, %{title: "Dep 2"})
      {:ok, task} = Tasks.insert(project, %{title: "Task"})

      conn =
        put(conn, ~p"/api/projects/#{project.id}/tasks/#{task.id}", %{
          title: "Task",
          depends_on_ids: [dep1.id, dep2.id]
        })

      assert json_response(conn, 200)

      blockers = Sacrum.Repo.TaskDependencies.get_direct_blockers(task)
      assert length(blockers) == 2
    end
  end
end
