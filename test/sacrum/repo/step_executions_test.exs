defmodule Sacrum.Repo.StepExecutionsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.StepExecutions
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.StepExecution

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp create_workflow do
    {:ok, user} = Users.insert(@valid_user_attrs)
    {:ok, project} = Projects.insert(user, %{name: "My Project"})
    {:ok, workflow} = Workflows.insert(project, %{name: "Default"})
    workflow
  end

  describe "insert/1" do
    test "creates step execution record" do
      workflow = create_workflow()
      task_id = Ecto.UUID.generate()

      assert {:ok, %StepExecution{} = execution} =
               StepExecutions.insert(workflow.user_id, %{
                 task_id: task_id,
                 workflow_id: workflow.id,
                 step_name: "review",
                 status: "completed",
                 model: "claude-3",
                 input_tokens: 100,
                 output_tokens: 50
               })

      assert execution.task_id == task_id
      assert execution.step_name == "review"
      assert execution.status == "completed"
      assert execution.model == "claude-3"
    end

    test "rejects missing task_id" do
      workflow = create_workflow()

      assert {:error, changeset} = StepExecutions.insert(workflow.user_id, %{step_name: "review"})
      assert %{task_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects missing step_name" do
      workflow = create_workflow()

      assert {:error, changeset} =
               StepExecutions.insert(workflow.user_id, %{task_id: Ecto.UUID.generate()})

      assert %{step_name: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "all/1" do
    test "returns executions ordered by inserted_at" do
      workflow = create_workflow()
      task_id = Ecto.UUID.generate()

      {:ok, _e1} =
        StepExecutions.insert(workflow.user_id, %{task_id: task_id, step_name: "draft"})

      {:ok, _e2} =
        StepExecutions.insert(workflow.user_id, %{task_id: task_id, step_name: "review"})

      executions =
        StepExecutions.all(conditions: [task_id: task_id], order_by: [asc: :inserted_at])

      assert length(executions) == 2
      assert Enum.map(executions, & &1.step_name) == ["draft", "review"]
    end

    test "does not return executions for other tasks" do
      workflow = create_workflow()
      task_id = Ecto.UUID.generate()
      other_task_id = Ecto.UUID.generate()

      {:ok, _} = StepExecutions.insert(workflow.user_id, %{task_id: task_id, step_name: "draft"})

      {:ok, _} =
        StepExecutions.insert(workflow.user_id, %{task_id: other_task_id, step_name: "review"})

      executions =
        StepExecutions.all(conditions: [task_id: task_id], order_by: [asc: :inserted_at])

      assert length(executions) == 1
    end
  end
end
