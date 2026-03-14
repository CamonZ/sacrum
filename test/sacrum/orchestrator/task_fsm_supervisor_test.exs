defmodule Sacrum.Orchestrator.TaskFSMSupervisorTest do
  use Sacrum.DataCase

  alias Sacrum.Orchestrator.TaskFSMSupervisor

  describe "start_child/1" do
    test "starts a new child process" do
      # Create a simple GenServer child spec
      child_spec = {Agent, fn -> :ok end}

      {:ok, pid} = TaskFSMSupervisor.start_child(child_spec)

      # Verify the child is running
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "starts multiple children" do
      child_spec = {Agent, fn -> :ok end}

      {:ok, pid1} = TaskFSMSupervisor.start_child(child_spec)
      {:ok, pid2} = TaskFSMSupervisor.start_child(child_spec)

      # Both should be running and different
      assert is_pid(pid1)
      assert is_pid(pid2)
      assert pid1 != pid2
      assert Process.alive?(pid1)
      assert Process.alive?(pid2)
    end
  end

  describe "terminate_child/1" do
    test "terminates a running child process" do
      child_spec = {Agent, fn -> :ok end}

      {:ok, pid} = TaskFSMSupervisor.start_child(child_spec)
      assert Process.alive?(pid)

      :ok = TaskFSMSupervisor.terminate_child(pid)

      # Give the process time to shut down
      Process.sleep(50)

      # Process should no longer be alive
      refute Process.alive?(pid)
    end

    test "returns error when terminating non-existent child" do
      fake_pid = spawn(fn -> :ok end)

      # Verify the fake process is alive
      assert Process.alive?(fake_pid)

      # Try to terminate it via the supervisor (it won't find it)
      result = TaskFSMSupervisor.terminate_child(fake_pid)

      # Should get an error since it's not supervised by our supervisor
      assert result == {:error, :not_found}
    end
  end

  describe "supervisor restart strategy" do
    test "supervisor keeps running even if children crash" do
      child_spec = {Agent, fn -> :ok end}

      {:ok, pid1} = TaskFSMSupervisor.start_child(child_spec)

      # Kill the child
      Process.exit(pid1, :kill)

      # Give the supervisor a moment to process
      Process.sleep(50)

      # Supervisor should still be able to start new children
      {:ok, pid2} = TaskFSMSupervisor.start_child(child_spec)
      assert is_pid(pid2)
      assert Process.alive?(pid2)
    end
  end
end
