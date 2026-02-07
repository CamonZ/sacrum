defmodule SacrumWeb.Graphql.SchemaTest do
  use SacrumWeb.ConnCase

  alias Sacrum.Accounts

  defp graphql(conn, query) do
    post(conn, "/graphql", %{"query" => query})
  end

  defp setup_user_and_project(_context) do
    user = create_user()
    {:ok, project} = Accounts.Projects.insert(user.id, %{name: "Test Project"})
    %{user: user, project: project}
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
  end

  describe "task queries" do
    setup [:setup_user_and_project]

    test "lists tasks for a project", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task 1"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { tasks(projectId: "#{project.id}") { id title shortId } }
        """)
        |> json_response(200)

      assert [found] = result["data"]["tasks"]
      assert found["id"] == task.id
      assert found["title"] == "Task 1"
      assert found["shortId"] != nil
    end

    test "filters tasks by level", %{conn: conn, user: user, project: project} do
      {:ok, _} = Accounts.Tasks.insert(user.id, project.id, %{title: "High", level: "high"})
      {:ok, _} = Accounts.Tasks.insert(user.id, project.id, %{title: "Low", level: "low"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { tasks(projectId: "#{project.id}", level: "high") { id title } }
        """)
        |> json_response(200)

      tasks = result["data"]["tasks"]
      assert length(tasks) == 1
      assert hd(tasks)["title"] == "High"
    end

    test "gets a single task by id", %{conn: conn, user: user, project: project} do
      {:ok, task} =
        Accounts.Tasks.insert(user.id, project.id, %{
          title: "My Task",
          description: "Details",
          level: "medium",
          priority: "normal",
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
      assert data["level"] == "medium"
      assert data["priority"] == "normal"
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
              level: "high"
              priority: "urgent"
              tags: ["bug", "critical"]
            ) { id title description level priority tags shortId }
          }
        """)
        |> json_response(200)

      data = result["data"]["createTask"]
      assert data["title"] == "New Task"
      assert data["description"] == "Task desc"
      assert data["level"] == "high"
      assert data["priority"] == "urgent"
      assert data["tags"] == ["bug", "critical"]
      assert data["shortId"] != nil
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
  end

  describe "workflow queries" do
    setup [:setup_user_and_project]

    test "lists workflows for a project", %{conn: conn, user: user, project: project} do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "My Workflow"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          { workflows(projectId: "#{project.id}") { id name description } }
        """)
        |> json_response(200)

      assert [found] = result["data"]["workflows"]
      assert found["id"] == wf.id
      assert found["name"] == "My Workflow"
    end

    test "gets a single workflow", %{conn: conn, user: user, project: project} do
      {:ok, wf} =
        Accounts.Workflows.insert(user.id, project.id, %{
          name: "WF",
          description: "A workflow"
        })

      result =
        conn
        |> authenticate(user)
        |> graphql(~s|{ workflow(id: "#{wf.id}") { id name description } }|)
        |> json_response(200)

      assert result["data"]["workflow"]["id"] == wf.id
      assert result["data"]["workflow"]["description"] == "A workflow"
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
              isDefault: true
            ) { id name description isDefault }
          }
        """)
        |> json_response(200)

      data = result["data"]["createWorkflow"]
      assert data["name"] == "New WF"
      assert data["isDefault"] == true
    end

    test "updates a workflow", %{conn: conn, user: user, project: project} do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "Original"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateWorkflow(id: "#{wf.id}", name: "Updated", description: "New desc") {
              id name description
            }
          }
        """)
        |> json_response(200)

      assert result["data"]["updateWorkflow"]["name"] == "Updated"
      assert result["data"]["updateWorkflow"]["description"] == "New desc"
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
              isFinal: false
            ) { id name goal stepOrder isFinal }
          }
        """)
        |> json_response(200)

      data = result["data"]["createWorkflowStep"]
      assert data["name"] == "Step 1"
      assert data["goal"] == "Test goal"
      assert data["stepOrder"] == 1
      assert data["isFinal"] == false
    end

    test "updates a workflow step", %{conn: conn, user: user, project: project} do
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})
      {:ok, step} = Accounts.WorkflowSteps.insert(wf, %{name: "Original"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            updateWorkflowStep(id: "#{step.id}", name: "Updated", isFinal: true) {
              id name isFinal
            }
          }
        """)
        |> json_response(200)

      assert result["data"]["updateWorkflowStep"]["name"] == "Updated"
      assert result["data"]["updateWorkflowStep"]["isFinal"] == true
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
  end

  describe "step execution mutations" do
    setup [:setup_user_and_project]

    test "creates a step execution", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})
      {:ok, wf} = Accounts.Workflows.insert(user.id, project.id, %{name: "WF"})

      result =
        conn
        |> authenticate(user)
        |> graphql("""
          mutation {
            createStepExecution(
              taskId: "#{task.id}"
              workflowId: "#{wf.id}"
              stepName: "analysis"
              status: "running"
              model: "claude-sonnet"
              modelProvider: "anthropic"
            ) { id stepName status model modelProvider taskId }
          }
        """)
        |> json_response(200)

      data = result["data"]["createStepExecution"]
      assert data["stepName"] == "analysis"
      assert data["status"] == "running"
      assert data["model"] == "claude-sonnet"
      assert data["modelProvider"] == "anthropic"
      assert data["taskId"] == task.id
    end

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
            ) { id status output inputTokens outputTokens }
          }
        """)
        |> json_response(200)

      data = result["data"]["updateStepExecution"]
      assert data["status"] == "completed"
      assert data["output"] == "Done"
      assert data["inputTokens"] == 100
      assert data["outputTokens"] == 50
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
            ) { id content stepExecutionId }
          }
        """)
        |> json_response(200)

      data = result["data"]["createSessionLog"]
      assert data["content"] == "Log entry content"
      assert data["stepExecutionId"] == exec.id
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
          { sessionLogs(stepExecutionId: "#{exec.id}") { id content } }
        """)
        |> json_response(200)

      assert [found] = result["data"]["sessionLogs"]
      assert found["id"] == log.id
      assert found["content"] == "A log"
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
              sectionType: "description"
              content: "Section content"
              sectionOrder: 1
            ) { id sectionType content sectionOrder taskId }
          }
        """)
        |> json_response(200)

      data = result["data"]["createSection"]
      assert data["sectionType"] == "description"
      assert data["content"] == "Section content"
      assert data["sectionOrder"] == 1
      assert data["taskId"] == task.id
    end

    test "updates a section", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      {:ok, section} =
        Accounts.Sections.insert(user.id, %{
          task_id: task.id,
          project_id: project.id,
          section_type: "description",
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

    test "deletes a section", %{conn: conn, user: user, project: project} do
      {:ok, task} = Accounts.Tasks.insert(user.id, project.id, %{title: "Task"})

      {:ok, section} =
        Accounts.Sections.insert(user.id, %{
          task_id: task.id,
          project_id: project.id,
          section_type: "description",
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

      assert [found] = result["data"]["project"]["workflows"]
      assert found["id"] == wf.id
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

    test "returns root tasks with no incomplete blockers", %{conn: conn, user: user, project: project} do
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

      assert [found] = result["data"]["listReady"]
      assert found["title"] == "Root Task"
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

    test "includes tasks whose blockers are all completed", %{conn: conn, user: user, project: project} do
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

    test "returns shortest dependency path between tasks", %{conn: conn, user: user, project: project} do
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

    test "returns empty path when no dependency path exists", %{conn: conn, user: user, project: project} do
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

    test "returns single-element path for direct dependency", %{conn: conn, user: user, project: project} do
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

    test "returns 404-like error when task does not exist", %{conn: conn, user: user, project: project} do
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

    test "deleting parent task also deletes all child tasks", %{conn: conn, user: user, project: project} do
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

    test "deleting task also deletes task dependencies and step executions", %{conn: conn, user: user, project: project} do
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
end
