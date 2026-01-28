defmodule Sacrum.Repo.SessionLogsTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Repo.SessionLogs
  alias Sacrum.Repo.StepExecutions
  alias Sacrum.Repo.Schemas.SessionLog

  defp create_execution do
    {:ok, execution} =
      StepExecutions.insert(%{
        task_id: Ecto.UUID.generate(),
        step_name: "review"
      })

    execution
  end

  describe "insert/1" do
    test "creates session log record" do
      execution = create_execution()

      assert {:ok, %SessionLog{} = log} =
               SessionLogs.insert(%{
                 step_execution_id: execution.id,
                 content: "Reviewing code changes..."
               })

      assert log.content == "Reviewing code changes..."
      assert log.step_execution_id == execution.id
    end

    test "rejects missing content" do
      execution = create_execution()

      assert {:error, changeset} =
               SessionLogs.insert(%{step_execution_id: execution.id})

      assert %{content: ["can't be blank"]} = errors_on(changeset)
    end

    test "rejects missing step_execution_id" do
      assert {:error, changeset} = SessionLogs.insert(%{content: "Some log"})
      assert %{step_execution_id: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "list_for_execution/1" do
    test "returns logs for a given execution" do
      execution = create_execution()
      {:ok, _} = SessionLogs.insert(%{step_execution_id: execution.id, content: "Log 1"})
      {:ok, _} = SessionLogs.insert(%{step_execution_id: execution.id, content: "Log 2"})

      logs = SessionLogs.list_for_execution(execution)
      assert length(logs) == 2
      assert Enum.map(logs, & &1.content) == ["Log 1", "Log 2"]
    end

    test "does not return logs from other executions" do
      execution1 = create_execution()
      execution2 = create_execution()
      {:ok, _} = SessionLogs.insert(%{step_execution_id: execution1.id, content: "Log 1"})
      {:ok, _} = SessionLogs.insert(%{step_execution_id: execution2.id, content: "Log 2"})

      logs = SessionLogs.list_for_execution(execution1)
      assert length(logs) == 1
      assert hd(logs).content == "Log 1"
    end
  end
end
