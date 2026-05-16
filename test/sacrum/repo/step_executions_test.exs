defmodule Sacrum.Repo.StepExecutionsTest do
  use Sacrum.DataCase, async: false

  alias Sacrum.Repo.StepExecutions
  alias Sacrum.Repo.Workflows
  alias Sacrum.Repo.Projects
  alias Sacrum.Repo.Users
  alias Sacrum.Repo.Schemas.StepExecution
  alias Sacrum.Repo.Tasks

  @valid_user_attrs %{
    email: "test@example.com",
    username: "testuser",
    password: "password123"
  }

  defp create_workflow do
    {:ok, user} = Users.insert(@valid_user_attrs)
    {:ok, project} = Projects.insert(user, %{name: "My Project"})
    {:ok, workflow} = Workflows.insert(project, %{name: "Default"})
    {workflow, project, user}
  end

  defp create_task(project, user_id) do
    {:ok, task} = Tasks.insert(project.id, user_id, %{title: "Test Task"})
    task
  end

  describe "insert/1" do
    test "creates step execution record" do
      {workflow, project, user} = create_workflow()
      task = create_task(project, user.id)

      assert {:ok, %StepExecution{} = execution} =
               StepExecutions.insert(workflow.user_id, %{
                 project_id: project.id,
                 task_id: task.id,
                 workflow_id: workflow.id,
                 step_name: "review",
                 step_type: "evaluate",
                 status: "completed",
                 model: "claude-3",
                 input_tokens: 100,
                 output_tokens: 50
               })

      assert execution.task_id == task.id
      assert execution.step_name == "review"
      assert execution.step_type == "evaluate"
      assert execution.status == "completed"
      assert execution.model == "claude-3"
    end

    test "defaults step_type to execute and rejects invalid values" do
      {workflow, project, user} = create_workflow()
      task = create_task(project, user.id)

      assert {:ok, %StepExecution{} = execution} =
               StepExecutions.insert(workflow.user_id, %{
                 project_id: project.id,
                 task_id: task.id,
                 workflow_id: workflow.id,
                 step_name: "manual"
               })

      assert execution.step_type == "execute"

      assert {:error, changeset} =
               StepExecutions.insert(workflow.user_id, %{
                 project_id: project.id,
                 task_id: task.id,
                 workflow_id: workflow.id,
                 step_name: "manual",
                 step_type: "bogus"
               })

      assert %{step_type: ["is invalid"]} = errors_on(changeset)
    end

    test "rejects missing task_id" do
      {workflow, project, _user} = create_workflow()

      assert {:error, changeset} =
               StepExecutions.insert(workflow.user_id, %{
                 project_id: project.id,
                 step_name: "review"
               })

      assert %{task_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects missing step_name" do
      {workflow, project, user} = create_workflow()
      task = create_task(project, user.id)

      assert {:error, changeset} =
               StepExecutions.insert(workflow.user_id, %{
                 project_id: project.id,
                 task_id: task.id
               })

      assert %{step_name: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "all/1" do
    test "returns executions ordered by inserted_at" do
      {workflow, project, user} = create_workflow()
      task = create_task(project, user.id)

      {:ok, _e1} =
        StepExecutions.insert(workflow.user_id, %{
          project_id: project.id,
          task_id: task.id,
          step_name: "draft"
        })

      {:ok, _e2} =
        StepExecutions.insert(workflow.user_id, %{
          project_id: project.id,
          task_id: task.id,
          step_name: "review"
        })

      executions =
        StepExecutions.all(conditions: [task_id: task.id], order_by: [asc: :inserted_at])

      assert length(executions) == 2
      assert Enum.map(executions, & &1.step_name) == ["draft", "review"]
    end

    test "does not return executions for other tasks" do
      {workflow, project, user} = create_workflow()
      task1 = create_task(project, user.id)
      task2 = create_task(project, user.id)

      {:ok, _} =
        StepExecutions.insert(workflow.user_id, %{
          project_id: project.id,
          task_id: task1.id,
          step_name: "draft"
        })

      {:ok, _} =
        StepExecutions.insert(workflow.user_id, %{
          project_id: project.id,
          task_id: task2.id,
          step_name: "review"
        })

      executions =
        StepExecutions.all(conditions: [task_id: task1.id], order_by: [asc: :inserted_at])

      assert length(executions) == 1
    end
  end

  describe "update_changeset/2" do
    test "casts update fields and validates required step_name" do
      {workflow, project, user} = create_workflow()
      task = create_task(project, user.id)

      {:ok, execution} =
        StepExecutions.insert(workflow.user_id, %{
          project_id: project.id,
          task_id: task.id,
          workflow_id: workflow.id,
          step_name: "draft",
          status: "in_progress"
        })

      changeset =
        StepExecution.update_changeset(execution, %{
          status: "completed",
          output: "Result text",
          output_tokens: 75,
          duration_ms: 1200
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :status) == "completed"
      assert Ecto.Changeset.get_change(changeset, :output) == "Result text"
      assert Ecto.Changeset.get_change(changeset, :output_tokens) == 75
      assert Ecto.Changeset.get_change(changeset, :duration_ms) == 1200
    end

    test "ignores task_id in update changeset" do
      {workflow, project, user} = create_workflow()
      task = create_task(project, user.id)

      {:ok, execution} =
        StepExecutions.insert(workflow.user_id, %{
          project_id: project.id,
          task_id: task.id,
          step_name: "draft"
        })

      changeset =
        StepExecution.update_changeset(execution, %{task_id: Ecto.UUID.generate()})

      assert changeset.valid?
      refute Ecto.Changeset.get_change(changeset, :task_id)
    end

    test "rejects nil step_name" do
      {workflow, project, user} = create_workflow()
      task = create_task(project, user.id)

      {:ok, execution} =
        StepExecutions.insert(workflow.user_id, %{
          project_id: project.id,
          task_id: task.id,
          step_name: "draft"
        })

      changeset = StepExecution.update_changeset(execution, %{step_name: nil})

      refute changeset.valid?
      assert %{step_name: ["can't be blank"]} = errors_on(changeset)
    end
  end
end
