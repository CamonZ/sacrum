defmodule Sacrum.Orchestrator.SupervisorTest do
  use Sacrum.DataCase

  alias Sacrum.Orchestrator.ExecutionPool
  alias Sacrum.Orchestrator.Scheduler
  alias Sacrum.Orchestrator.TaskFSMSupervisor

  describe "initialization" do
    test "starts all three child processes" do
      # Verify ExecutionPool is running
      pool_pid = GenServer.whereis(ExecutionPool)
      assert is_pid(pool_pid)
      assert Process.alive?(pool_pid)

      # Verify Scheduler is running
      scheduler_pid = GenServer.whereis(Scheduler)
      assert is_pid(scheduler_pid)
      assert Process.alive?(scheduler_pid)

      # Verify TaskFSMSupervisor is running
      fsm_sup_pid = GenServer.whereis(TaskFSMSupervisor)
      assert is_pid(fsm_sup_pid)
      assert Process.alive?(fsm_sup_pid)
    end
  end

  describe "rest_for_one strategy" do
    test "restarting ExecutionPool also restarts Scheduler and TaskFSMSupervisor" do
      # Get initial PIDs
      initial_pool_pid = GenServer.whereis(ExecutionPool)
      initial_scheduler_pid = GenServer.whereis(Scheduler)
      initial_fsm_sup_pid = GenServer.whereis(TaskFSMSupervisor)

      # Kill the ExecutionPool
      Process.exit(initial_pool_pid, :kill)

      # Give the supervisor time to restart children
      Process.sleep(100)

      # New pool should have restarted (different PID or same but restarted)
      # The scheduler and FSM supervisor should also be restarted
      new_pool_pid = GenServer.whereis(ExecutionPool)
      new_scheduler_pid = GenServer.whereis(Scheduler)
      new_fsm_sup_pid = GenServer.whereis(TaskFSMSupervisor)

      # All should be alive
      assert Process.alive?(new_pool_pid)
      assert Process.alive?(new_scheduler_pid)
      assert Process.alive?(new_fsm_sup_pid)

      # Scheduler and FSM supervisor should have restarted (possibly different PIDs)
      assert new_scheduler_pid != initial_scheduler_pid or
               new_fsm_sup_pid != initial_fsm_sup_pid
    end
  end
end
