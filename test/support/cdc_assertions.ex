defmodule Sacrum.CdcAssertions do
  @moduledoc """
  Helpers for asserting CDC-derived ProjectChannel events in tests.
  """

  import ExUnit.Assertions

  @spec subscribe_project(binary()) :: :ok | {:error, term()}
  def subscribe_project(project_id) do
    Phoenix.PubSub.subscribe(Sacrum.PubSub, "project:#{project_id}")
  end

  @spec assert_project_broadcast(binary(), map(), timeout()) :: map()
  def assert_project_broadcast(event, expected_payload, timeout \\ 100) do
    payload = receive_project_broadcast(event, expected_payload, timeout)

    for {key, expected_value} <- expected_payload do
      assert Map.fetch!(payload, key) == expected_value
    end

    payload
  end

  @spec refute_project_broadcast(binary(), timeout()) :: true
  def refute_project_broadcast(event, timeout \\ 100) do
    refute_receive %Phoenix.Socket.Broadcast{event: ^event}, timeout
  end

  defp receive_project_broadcast(event, expected_payload, timeout) do
    receive do
      %Phoenix.Socket.Broadcast{event: ^event, payload: payload} ->
        if payload_matches?(payload, expected_payload) do
          payload
        else
          receive_project_broadcast(event, expected_payload, timeout)
        end

      %Phoenix.Socket.Broadcast{} ->
        receive_project_broadcast(event, expected_payload, timeout)
    after
      timeout ->
        flunk(
          "expected project broadcast #{inspect(event)} with payload #{inspect(expected_payload)}"
        )
    end
  end

  defp payload_matches?(payload, expected_payload) do
    Enum.all?(expected_payload, fn {key, expected_value} ->
      Map.get(payload, key) == expected_value
    end)
  end
end
