defmodule Sacrum.Accounts.WorkflowStepsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Accounts.WorkflowSteps
  alias Sacrum.Accounts.Workflows
  alias Sacrum.Accounts.Tasks
  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.WorkflowStep

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp create_user(attrs \\ @valid_user_attrs) do
    {:ok, user} = Users.insert(attrs)
    user
  end

  defp create_workflow(user) do
    {:ok, project} = Projects.insert(user.id, %{name: "Test Project"})
    {:ok, workflow} = Workflows.insert(user.id, project.id, %{name: "Test Workflow"})
    {project, workflow}
  end

  describe "insert/2 with attrs" do
    test "creates step scoped to user_id, project_id, and workflow_id" do
      user = create_user()
      {project, workflow} = create_workflow(user)

      assert {:ok, %WorkflowStep{} = step} =
               WorkflowSteps.insert(user.id, %{
                 "workflow_id" => workflow.id,
                 "project_id" => project.id,
                 "name" => "Draft"
               })

      assert step.user_id == user.id
      assert step.project_id == project.id
      assert step.workflow_id == workflow.id
      assert step.name == "Draft"
    end

    test "accepts workflow struct and extracts ids" do
      user = create_user()
      {project, workflow} = create_workflow(user)

      assert {:ok, %WorkflowStep{} = step} =
               WorkflowSteps.insert(workflow, %{name: "Draft"})

      assert step.user_id == user.id
      assert step.project_id == project.id
      assert step.workflow_id == workflow.id
    end
  end

  describe "get_by/2" do
    test "returns step only if scoped to user" do
      user1 = create_user()
      {_project1, workflow1} = create_workflow(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {_project2, workflow2} = create_workflow(user2)

      {:ok, step} = WorkflowSteps.insert(workflow1, %{name: "User1 Step"})
      {:ok, _} = WorkflowSteps.insert(workflow2, %{name: "User2 Step"})

      # User1 can access their step
      assert {:ok, found} = WorkflowSteps.get_by(user1.id, conditions: [id: step.id])
      assert found.id == step.id
      assert found.user_id == user1.id

      # User2 cannot access user1's step
      assert {:error, :not_found} = WorkflowSteps.get_by(user2.id, conditions: [id: step.id])
    end
  end

  describe "delete/1" do
    test "translates assigned-task conflicts into a client-safe error" do
      user = create_user()
      {project, workflow} = create_workflow(user)
      {:ok, step} = WorkflowSteps.insert(workflow, %{name: "Assigned step"})
      {:ok, workflow} = Workflows.update(workflow, %{initial_step_id: step.id})

      {:ok, task_one} =
        Tasks.insert(user.id, project.id, %{title: "Task one", workflow_id: workflow.id})

      {:ok, task_two} =
        Tasks.insert(user.id, project.id, %{title: "Task two", workflow_id: workflow.id})

      assert task_one.current_step_id == step.id
      assert task_two.current_step_id == step.id

      assert {:error, "cannot delete a workflow step that is assigned to one or more tasks"} =
               WorkflowSteps.delete(step)

      assert {:ok, found_step} = WorkflowSteps.get_by(user.id, conditions: [id: step.id])
      assert found_step.id == step.id

      assert {:ok, found_task_one} = Tasks.get_by(user.id, conditions: [id: task_one.id])
      assert found_task_one.current_step_id == step.id
      assert found_task_one.title == "Task one"

      assert {:ok, found_task_two} = Tasks.get_by(user.id, conditions: [id: task_two.id])
      assert found_task_two.current_step_id == step.id
      assert found_task_two.title == "Task two"
    end
  end

  describe "list_by/2" do
    test "returns only steps scoped to user" do
      user1 = create_user()
      {_project1, workflow1} = create_workflow(user1)

      user2 =
        create_user(%{email: "other@example.com", username: "other", password: "password123"})

      {_project2, workflow2} = create_workflow(user2)

      {:ok, _} = WorkflowSteps.insert(workflow1, %{name: "User1 Step"})
      {:ok, _} = WorkflowSteps.insert(workflow2, %{name: "User2 Step"})

      steps = WorkflowSteps.list_by(user1.id)
      # Project creation auto-creates a Backlog step; create_workflow adds a second.
      assert length(steps) == 2
      assert Enum.all?(steps, &(&1.user_id == user1.id))
    end

    test "filters by workflow_id" do
      user = create_user()
      {project, workflow1} = create_workflow(user)
      {:ok, workflow2} = Workflows.insert(user.id, project.id, %{name: "Workflow 2"})

      {:ok, _} = WorkflowSteps.insert(workflow1, %{name: "Step 1"})
      {:ok, _} = WorkflowSteps.insert(workflow2, %{name: "Step 2"})

      steps = WorkflowSteps.list_by(user.id, conditions: [workflow_id: workflow1.id])
      assert length(steps) == 1
      assert hd(steps).workflow_id == workflow1.id
    end
  end

  describe "step_type field" do
    test "defaults to execute when not specified" do
      user = create_user()
      {_project, workflow} = create_workflow(user)

      assert {:ok, %WorkflowStep{} = step} =
               WorkflowSteps.insert(workflow, %{name: "Draft"})

      assert step.step_type == :execute
    end

    test "creates step with each valid step_type" do
      user = create_user()
      {_project, workflow} = create_workflow(user)

      for type <- ~w(execute evaluate route finish) do
        attrs =
          case type do
            "finish" -> %{prompt: nil}
            "route" -> %{prompt: "Choose a destination"}
            _ -> %{}
          end

        assert {:ok, %WorkflowStep{} = step} =
                 WorkflowSteps.insert(
                   workflow,
                   Map.merge(%{name: "Step #{type}", step_type: type}, attrs)
                 )

        assert step.step_type == String.to_existing_atom(type)
      end
    end

    test "rejects invalid step_type" do
      user = create_user()
      {_project, workflow} = create_workflow(user)

      assert {:error, changeset} =
               WorkflowSteps.insert(workflow, %{name: "Bad", step_type: "invalid"})

      assert %{step_type: ["is invalid"]} = errors_on(changeset)
    end

    test "updates step_type" do
      user = create_user()
      {_project, workflow} = create_workflow(user)

      {:ok, step} = WorkflowSteps.insert(workflow, %{name: "Draft"})
      assert step.step_type == :execute

      assert {:ok, updated} =
               WorkflowSteps.update(step, %{step_type: "route", prompt: "Choose a destination"})

      assert updated.step_type == :route
    end
  end

  describe "prompt field" do
    test "inserts step with prompt" do
      user = create_user()
      {_project, workflow} = create_workflow(user)

      assert {:ok, %WorkflowStep{} = step} =
               WorkflowSteps.insert(workflow, %{
                 name: "Review",
                 prompt: "Please review the following content"
               })

      assert step.prompt == "Please review the following content"
    end

    test "updates step with prompt" do
      user = create_user()
      {_project, workflow} = create_workflow(user)

      {:ok, step} = WorkflowSteps.insert(workflow, %{name: "Review"})

      assert {:ok, updated_step} =
               WorkflowSteps.update(step, %{
                 prompt: "Updated prompt"
               })

      assert updated_step.prompt == "Updated prompt"
    end

    test "handles optional prompt field" do
      user = create_user()
      {_project, workflow} = create_workflow(user)

      # Create without prompt
      assert {:ok, step} = WorkflowSteps.insert(workflow, %{name: "Review"})
      assert is_nil(step.prompt)

      # Update to add it
      assert {:ok, updated_step} =
               WorkflowSteps.update(step, %{prompt: "New prompt"})

      assert updated_step.prompt == "New prompt"
    end
  end

  describe "route configuration" do
    test "rejects an unsupported route_config version" do
      user = create_user()
      {_project, workflow} = create_workflow(user)

      assert {:error, changeset} =
               WorkflowSteps.insert(workflow, %{
                 name: "Route",
                 step_type: "route",
                 prompt: "Choose a destination",
                 route_config: %{
                   "version" => 2,
                   "match_policy" => "exactly_one",
                   "rules" => [
                     %{
                       "id" => "approved",
                       "when" => %{
                         "ref" => "previous_output.route.result",
                         "op" => "eq",
                         "value" => "approved"
                       },
                       "transition" => %{
                         "type" => "intra_workflow",
                         "step_id" => "00000000-0000-0000-0000-000000000001"
                       }
                     }
                   ]
                 }
               })

      assert %{route_config: [message]} = errors_on(changeset)
      assert message =~ "$.version: only version 1 is supported"
    end

    test "rejects ill-typed staged configurations" do
      user = create_user()
      {_project, workflow} = create_workflow(user)

      cases = [
        {%{"ref" => "task.tags", "op" => "eq", "value" => "backend"}, default_transition(),
         "$.rules[0].when.op"},
        {%{"ref" => "execution.step_visit_count", "op" => "gte", "value" => 0},
         default_transition(), "$.rules[0].when.value"},
        {%{"ref" => "task.tags", "op" => "contains_all", "value" => []}, default_transition(),
         "$.rules[0].when.value"},
        {%{"ref" => "task.tags", "op" => "contains", "value" => "backend"}, nil, "$.default"}
      ]

      for {condition, default, expected_path} <- cases do
        assert {:error, changeset} =
                 WorkflowSteps.insert(workflow, %{
                   name: "Route",
                   step_type: "route",
                   prompt: "Choose a destination",
                   route_config: route_config(condition, default)
                 })

        assert %{route_config: [message]} = errors_on(changeset)
        assert message =~ expected_path
      end
    end

    test "requires graph prerequisites for a promptless configured route" do
      user = create_user()
      {_project, workflow} = create_workflow(user)

      assert {:error, changeset} =
               WorkflowSteps.insert(workflow, %{
                 name: "Route",
                 step_type: "route",
                 prompt: nil,
                 route_config:
                   route_config(%{
                     "ref" => "previous_output.route.result",
                     "op" => "eq",
                     "value" => "approved"
                   })
               })

      assert %{route_config: [message]} = errors_on(changeset)
      assert message =~ "$.predecessors"
    end

    test "allows a promptless unconfigured route as an authoring draft" do
      user = create_user()
      {_project, workflow} = create_workflow(user)

      assert {:ok, draft} =
               WorkflowSteps.insert(workflow, %{name: "Route", step_type: "route", prompt: nil})

      assert draft.route_config == nil
      assert draft.output_schema == nil
    end
  end

  defp route_config(condition, default \\ default_transition()) do
    %{
      "version" => 1,
      "match_policy" => "exactly_one",
      "rules" => [
        %{
          "id" => "route",
          "when" => condition,
          "transition" => %{
            "type" => "intra_workflow",
            "step_id" => "00000000-0000-0000-0000-000000000001"
          }
        }
      ],
      "default" => default
    }
  end

  defp default_transition do
    %{
      "transition" => %{
        "type" => "intra_workflow",
        "step_id" => "00000000-0000-0000-0000-000000000002"
      }
    }
  end
end
