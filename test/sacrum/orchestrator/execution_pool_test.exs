defmodule Sacrum.Orchestrator.ExecutionPoolTest do
  use Sacrum.DataCase

  alias Sacrum.Orchestrator.ExecutionPool

  setup do
    original_max = Application.get_env(:sacrum, :max_concurrent_executions)

    on_exit(fn ->
      Application.put_env(:sacrum, :max_concurrent_executions, original_max)
    end)

    # Drain any leftover slots from previous tests by waiting for clean state
    wait_for_clean_pool()

    :ok
  end

  defp wait_for_clean_pool do
    status = ExecutionPool.pool_status()

    if status.in_use_count > 0 do
      Process.sleep(50)
      wait_for_clean_pool()
    end
  end

  describe "request_slot/2 and release_slot/1" do
    test "grants slots up to max_concurrent limit" do
      slots =
        Enum.map(1..5, fn _i ->
          {:ok, slot} = ExecutionPool.request_slot(self())
          slot
        end)

      assert length(Enum.uniq(slots)) == 5

      status = ExecutionPool.pool_status()
      assert status.available_slots == 0
      assert status.in_use_count == 5

      Enum.each(slots, &ExecutionPool.release_slot/1)
    end

    test "queues requests when all slots are in use" do
      parent = self()

      slots =
        Enum.map(1..5, fn _i ->
          {:ok, slot} = ExecutionPool.request_slot(self())
          slot
        end)

      {:ok, _waiter_pid} =
        Task.start(fn ->
          {:ok, slot} = ExecutionPool.request_slot(self(), 5000)
          send(parent, {:slot_received, slot})
          Process.sleep(100)
        end)

      Process.sleep(50)

      status = ExecutionPool.pool_status()
      assert status.queue_length == 1

      ExecutionPool.release_slot(hd(slots))
      assert_receive {:slot_received, _slot}, 1000

      Enum.each(tl(slots), &ExecutionPool.release_slot/1)
    end

    test "releases slot and dequeues next request" do
      slots =
        Enum.map(1..5, fn _i ->
          {:ok, slot} = ExecutionPool.request_slot(self())
          slot
        end)

      parent = self()

      {:ok, _waiter1_pid} =
        Task.start(fn ->
          {:ok, slot} = ExecutionPool.request_slot(self(), 5000)
          send(parent, {:waiter1_received, slot})
          Process.sleep(200)
        end)

      {:ok, _waiter2_pid} =
        Task.start(fn ->
          {:ok, slot} = ExecutionPool.request_slot(self(), 5000)
          send(parent, {:waiter2_received, slot})
          Process.sleep(200)
        end)

      Process.sleep(50)

      status = ExecutionPool.pool_status()
      assert status.queue_length == 2

      ExecutionPool.release_slot(hd(slots))
      assert_receive {:waiter1_received, _slot}, 1000

      status = ExecutionPool.pool_status()
      assert status.in_use_count == 5
      assert status.queue_length == 1

      Enum.each(tl(slots), &ExecutionPool.release_slot/1)
      assert_receive {:waiter2_received, _slot}, 1000
    end

    test "auto-releases slot when monitored process dies" do
      slots =
        Enum.map(1..4, fn _i ->
          {:ok, slot} = ExecutionPool.request_slot(self())
          slot
        end)

      parent = self()

      {:ok, holder_pid} =
        Task.start(fn ->
          {:ok, slot} = ExecutionPool.request_slot(self(), 5000)
          send(parent, {:holder_got_slot, slot})
          Process.sleep(5000)
        end)

      assert_receive {:holder_got_slot, _slot}, 1000
      assert ExecutionPool.pool_status().in_use_count == 5

      {:ok, _waiter_pid} =
        Task.start(fn ->
          {:ok, slot} = ExecutionPool.request_slot(self(), 5000)
          send(parent, {:waiter_received, slot})
          Process.sleep(200)
        end)

      Process.sleep(50)
      assert ExecutionPool.pool_status().queue_length == 1

      Process.exit(holder_pid, :kill)
      assert_receive {:waiter_received, _slot}, 1000

      Enum.each(slots, &ExecutionPool.release_slot/1)
    end

    test "handles multiple slot releases correctly" do
      slots =
        Enum.map(1..3, fn _i ->
          {:ok, slot} = ExecutionPool.request_slot(self())
          slot
        end)

      Enum.each(slots, &ExecutionPool.release_slot/1)

      status = ExecutionPool.pool_status()
      assert status.available_slots == 5
      assert status.in_use_count == 0
    end

    test "handles release of already-released slot gracefully" do
      {:ok, slot} = ExecutionPool.request_slot(self())
      :ok = ExecutionPool.release_slot(slot)
      :ok = ExecutionPool.release_slot(slot)

      {:ok, slot2} = ExecutionPool.request_slot(self())
      ExecutionPool.release_slot(slot2)
    end
  end

  describe "pool_status/0" do
    test "returns accurate pool status" do
      {:ok, slot} = ExecutionPool.request_slot(self())

      status = ExecutionPool.pool_status()

      assert status.available_slots == 4
      assert status.in_use_count == 1
      assert status.queue_length == 0

      ExecutionPool.release_slot(slot)
    end
  end

  describe "concurrent execution" do
    test "multiple processes can request and release slots concurrently" do
      processes =
        Enum.map(1..10, fn _i ->
          Task.async(fn ->
            {:ok, slot} = ExecutionPool.request_slot(self(), :infinity)
            Process.sleep(50)
            ExecutionPool.release_slot(slot)
            :ok
          end)
        end)

      results = Task.await_many(processes, 30_000)
      assert Enum.all?(results, &(&1 == :ok))

      status = ExecutionPool.pool_status()
      assert status.available_slots == 5
      assert status.in_use_count == 0
      assert status.queue_length == 0
    end
  end
end
