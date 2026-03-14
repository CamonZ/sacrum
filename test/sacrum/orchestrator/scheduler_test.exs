defmodule Sacrum.Orchestrator.SchedulerTest do
  use Sacrum.DataCase

  alias Sacrum.Orchestrator.Scheduler
  alias Ecto.UUID

  describe "schedule_task/1" do
    test "accepts a task for scheduling" do
      task = %{
        id: UUID.generate(),
        title: "Test Task"
      }

      :ok = Scheduler.schedule_task(task)
    end

    test "handles multiple task schedules" do
      task1 = %{id: UUID.generate(), title: "Task 1"}
      task2 = %{id: UUID.generate(), title: "Task 2"}

      :ok = Scheduler.schedule_task(task1)
      :ok = Scheduler.schedule_task(task2)
    end
  end

  describe "notify_task_completed/2" do
    test "notifies task completion" do
      task_id = UUID.generate()
      result = %{status: "completed"}

      :ok = Scheduler.notify_task_completed(task_id, result)
    end

    test "handles multiple completion notifications" do
      task_id1 = UUID.generate()
      task_id2 = UUID.generate()

      :ok = Scheduler.notify_task_completed(task_id1, %{status: "completed"})
      :ok = Scheduler.notify_task_completed(task_id2, %{status: "completed"})
    end
  end
end
