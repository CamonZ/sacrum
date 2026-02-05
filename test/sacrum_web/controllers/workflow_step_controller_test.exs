defmodule SacrumWeb.WorkflowStepControllerTest do
  use SacrumWeb.ConnCase, async: true

  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.WorkflowSteps
  alias Sacrum.Repo.StepTransitions
  alias Sacrum.Repo.Tasks
  alias Sacrum.Repo.TaskWorkflows

  defp setup_authenticated(%{conn: conn}) do
    user = create_user()
    conn = authenticate(conn, user)
    {:ok, project} = Projects.insert(user, %{name: "Test Project"})
    {:ok, workflow} = Workflows.insert(project, %{name: "Default"})
    %{conn: conn, user: user, project: project, workflow: workflow}
  end

  describe "GET /api/workflow-steps" do
    setup :setup_authenticated

    test "returns 200 with steps list", %{conn: conn, workflow: workflow} do
      {:ok, _} = WorkflowSteps.insert(workflow, %{name: "Draft", step_order: 1})
      {:ok, _} = WorkflowSteps.insert(workflow, %{name: "Review", step_order: 2})

      conn = get(conn, ~p"/api/workflow-steps?workflow_id=#{workflow.id}")

      assert %{"data" => steps} = json_response(conn, 200)
      assert length(steps) == 2
    end

    test "returns all steps across workflows when no workflow_id given", %{
      conn: conn,
      workflow: workflow,
      project: project
    } do
      {:ok, _} = WorkflowSteps.insert(workflow, %{name: "Draft", step_order: 1})
      {:ok, other_workflow} = Workflows.insert(project, %{name: "Other"})
      {:ok, _} = WorkflowSteps.insert(other_workflow, %{name: "Review", step_order: 1})

      conn = get(conn, ~p"/api/workflow-steps")

      assert %{"data" => steps} = json_response(conn, 200)
      assert length(steps) == 2
    end

    test "filters by workflow_id when provided", %{
      conn: conn,
      workflow: workflow,
      project: project
    } do
      {:ok, _} = WorkflowSteps.insert(workflow, %{name: "Draft", step_order: 1})
      {:ok, other_workflow} = Workflows.insert(project, %{name: "Other"})
      {:ok, _} = WorkflowSteps.insert(other_workflow, %{name: "Review", step_order: 1})

      conn = get(conn, ~p"/api/workflow-steps?workflow_id=#{workflow.id}")

      assert %{"data" => steps} = json_response(conn, 200)
      assert length(steps) == 1
      assert hd(steps)["name"] == "Draft"
    end
  end

  describe "POST /api/workflow-steps" do
    setup :setup_authenticated

    test "creates step and returns 201", %{conn: conn, workflow: workflow} do
      conn =
        post(conn, ~p"/api/workflow-steps", %{
          workflow_id: workflow.id,
          name: "Review",
          goal: "Review the code",
          step_order: 1
        })

      assert %{
               "data" => %{
                 "name" => "Review",
                 "goal" => "Review the code",
                 "step_order" => 1
               }
             } = json_response(conn, 201)
    end

    test "returns 422 with missing name", %{conn: conn, workflow: workflow} do
      conn = post(conn, ~p"/api/workflow-steps", %{workflow_id: workflow.id})
      assert %{"errors" => %{"name" => _}} = json_response(conn, 422)
    end
  end

  describe "PATCH /api/workflow-steps/:id" do
    setup :setup_authenticated

    test "updates step and returns 200", %{conn: conn, workflow: workflow} do
      {:ok, step} = WorkflowSteps.insert(workflow, %{name: "Draft", step_order: 1})

      conn =
        patch(conn, ~p"/api/workflow-steps/#{step.id}", %{
          name: "Updated Draft",
          is_final: true
        })

      assert %{
               "data" => %{
                 "name" => "Updated Draft",
                 "is_final" => true
               }
             } = json_response(conn, 200)
    end

    test "syncs transitions and returns them in response", %{conn: conn, workflow: workflow} do
      {:ok, step1} = WorkflowSteps.insert(workflow, %{name: "Backlog", step_order: 1})
      {:ok, step2} = WorkflowSteps.insert(workflow, %{name: "In Progress", step_order: 2})
      {:ok, step3} = WorkflowSteps.insert(workflow, %{name: "Done", step_order: 3})

      conn =
        patch(conn, ~p"/api/workflow-steps/#{step1.id}", %{
          transitions: [
            %{to_step_id: step2.id, label: "start"},
            %{to_step_id: step3.id, label: "skip to done"}
          ]
        })

      assert %{
               "data" => %{
                 "transitions" => transitions
               }
             } = json_response(conn, 200)

      assert length(transitions) == 2
      to_ids = Enum.map(transitions, & &1["to_step_id"]) |> Enum.sort()
      assert to_ids == Enum.sort([step2.id, step3.id])
    end

    test "syncs transitions removes absent ones", %{
      conn: conn,
      workflow: workflow,
      project: project
    } do
      {:ok, step1} = WorkflowSteps.insert(workflow, %{name: "Backlog", step_order: 1})
      {:ok, step2} = WorkflowSteps.insert(workflow, %{name: "In Progress", step_order: 2})
      {:ok, step3} = WorkflowSteps.insert(workflow, %{name: "Done", step_order: 3})

      # Create initial transitions
      {:ok, _} =
        StepTransitions.insert(step1.user_id, %{
          project_id: project.id,
          from_step_id: step1.id,
          to_step_id: step2.id
        })

      {:ok, _} =
        StepTransitions.insert(step1.user_id, %{
          project_id: project.id,
          from_step_id: step1.id,
          to_step_id: step3.id
        })

      # Sync to only step3
      conn =
        patch(conn, ~p"/api/workflow-steps/#{step1.id}", %{
          transitions: [%{to_step_id: step3.id}]
        })

      assert %{
               "data" => %{
                 "transitions" => transitions
               }
             } = json_response(conn, 200)

      assert length(transitions) == 1
      assert hd(transitions)["to_step_id"] == step3.id
    end

    test "empty transitions array removes all transitions", %{
      conn: conn,
      workflow: workflow,
      project: project
    } do
      {:ok, step1} = WorkflowSteps.insert(workflow, %{name: "Backlog", step_order: 1})
      {:ok, step2} = WorkflowSteps.insert(workflow, %{name: "In Progress", step_order: 2})

      {:ok, _} =
        StepTransitions.insert(step1.user_id, %{
          project_id: project.id,
          from_step_id: step1.id,
          to_step_id: step2.id
        })

      conn =
        patch(conn, ~p"/api/workflow-steps/#{step1.id}", %{
          transitions: []
        })

      assert %{
               "data" => %{
                 "transitions" => []
               }
             } = json_response(conn, 200)
    end

    test "returns 422 for to_step_id in different workflow", %{
      conn: conn,
      workflow: workflow,
      project: project
    } do
      {:ok, step1} = WorkflowSteps.insert(workflow, %{name: "Backlog", step_order: 1})
      {:ok, other_workflow} = Workflows.insert(project, %{name: "Other"})

      {:ok, other_step} =
        WorkflowSteps.insert(other_workflow, %{name: "Other Step", step_order: 1})

      conn =
        patch(conn, ~p"/api/workflow-steps/#{step1.id}", %{
          transitions: [%{to_step_id: other_step.id}]
        })

      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 422)
      assert detail =~ "same workflow"
    end

    test "returns 422 for duplicate to_step_id entries", %{conn: conn, workflow: workflow} do
      {:ok, step1} = WorkflowSteps.insert(workflow, %{name: "Backlog", step_order: 1})
      {:ok, step2} = WorkflowSteps.insert(workflow, %{name: "In Progress", step_order: 2})

      conn =
        patch(conn, ~p"/api/workflow-steps/#{step1.id}", %{
          transitions: [
            %{to_step_id: step2.id, label: "a"},
            %{to_step_id: step2.id, label: "b"}
          ]
        })

      assert %{"errors" => %{"detail" => detail}} = json_response(conn, 422)
      assert detail =~ "duplicate"
    end

    test "move-to works after setting transitions via PATCH", %{
      conn: conn,
      workflow: workflow,
      project: project
    } do
      {:ok, step1} = WorkflowSteps.insert(workflow, %{name: "Backlog", step_order: 1})
      {:ok, step2} = WorkflowSteps.insert(workflow, %{name: "In Progress", step_order: 2})

      {:ok, workflow} = Workflows.update(workflow, %{initial_step_id: step1.id})

      # Set transitions via PATCH
      patch(conn, ~p"/api/workflow-steps/#{step1.id}", %{
        transitions: [%{to_step_id: step2.id}]
      })

      # Create and assign task
      {:ok, task} = Tasks.insert(project, %{title: "Test"})
      {:ok, task} = TaskWorkflows.assign_workflow(task, workflow)

      # Move to step2 should work
      conn =
        post(conn, ~p"/api/tasks/#{task.id}/move-to", %{step_id: step2.id})

      assert %{
               "data" => %{
                 "current_step_id" => step_id
               }
             } = json_response(conn, 200)

      assert step_id == step2.id
    end
  end

  describe "GET /api/workflow-steps/:id" do
    setup :setup_authenticated

    test "includes transitions in show response", %{
      conn: conn,
      workflow: workflow,
      project: project
    } do
      {:ok, step1} = WorkflowSteps.insert(workflow, %{name: "Backlog", step_order: 1})
      {:ok, step2} = WorkflowSteps.insert(workflow, %{name: "In Progress", step_order: 2})

      {:ok, _} =
        StepTransitions.insert(step1.user_id, %{
          project_id: project.id,
          from_step_id: step1.id,
          to_step_id: step2.id,
          label: "start"
        })

      conn = get(conn, ~p"/api/workflow-steps/#{step1.id}")

      assert %{
               "data" => %{
                 "transitions" => [%{"to_step_id" => to_id, "label" => "start"}]
               }
             } = json_response(conn, 200)

      assert to_id == step2.id
    end
  end

  describe "DELETE /api/workflow-steps/:id" do
    setup :setup_authenticated

    test "removes step and returns 204", %{conn: conn, workflow: workflow} do
      {:ok, step} = WorkflowSteps.insert(workflow, %{name: "Draft"})

      conn = delete(conn, ~p"/api/workflow-steps/#{step.id}")
      assert response(conn, 204)
    end
  end
end
