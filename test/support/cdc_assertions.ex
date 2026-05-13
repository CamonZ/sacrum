defmodule Sacrum.CdcAssertions do
  @moduledoc """
  Helpers for asserting CDC-derived ProjectChannel events in tests.

  These helpers build WalEx events from committed row images and dispatch them
  through the CDC projector, so tests do not need to call inline Broadcaster
  helpers directly.
  """

  import ExUnit.Assertions

  alias Sacrum.Realtime.Cdc.Projector
  @spec subscribe_project(binary()) :: :ok | {:error, term()}
  def subscribe_project(project_id) do
    Phoenix.PubSub.subscribe(Sacrum.PubSub, "project:#{project_id}")
  end

  @spec project_insert(binary(), struct() | map(), keyword()) :: {:ok, [map()]}
  def project_insert(table, record, opts \\ []) do
    table
    |> insert_event(record, opts)
    |> Projector.project_events()
  end

  @spec project_update(binary(), struct() | map(), struct() | map(), keyword()) :: {:ok, [map()]}
  def project_update(table, old_record, new_record, opts \\ []) do
    table
    |> update_event(old_record, new_record, opts)
    |> Projector.project_events()
  end

  @spec project_delete(binary(), struct() | map(), keyword()) :: {:ok, [map()]}
  def project_delete(table, record, opts \\ []) do
    table
    |> delete_event(record, opts)
    |> Projector.project_events()
  end

  @spec assert_project_broadcast(binary(), map(), timeout()) :: map()
  def assert_project_broadcast(event, expected_payload, timeout \\ 100) do
    assert_receive %Phoenix.Socket.Broadcast{event: ^event, payload: payload}, timeout

    for {key, expected_value} <- expected_payload do
      assert Map.fetch!(payload, key) == expected_value
    end

    payload
  end

  @spec refute_project_broadcast(binary(), timeout()) :: true
  def refute_project_broadcast(event, timeout \\ 100) do
    refute_receive %Phoenix.Socket.Broadcast{event: ^event}, timeout
  end

  @spec insert_event(binary(), struct() | map(), keyword()) :: WalEx.Event.t()
  def insert_event(table, record, opts \\ []) do
    %WalEx.Event{
      name: String.to_atom(table),
      type: :insert,
      source: source(table),
      new_record: record_map(record),
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now()),
      lsn: Keyword.get(opts, :lsn, {0, System.unique_integer([:positive])})
    }
  end

  @spec update_event(binary(), struct() | map(), struct() | map(), keyword()) :: WalEx.Event.t()
  def update_event(table, old_record, new_record, opts \\ []) do
    old_record = record_map(old_record)
    new_record = record_map(new_record)

    %WalEx.Event{
      name: String.to_atom(table),
      type: :update,
      source: source(table),
      new_record: new_record,
      changes: changes(old_record, new_record),
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now()),
      lsn: Keyword.get(opts, :lsn, {0, System.unique_integer([:positive])})
    }
  end

  @spec delete_event(binary(), struct() | map(), keyword()) :: WalEx.Event.t()
  def delete_event(table, record, opts \\ []) do
    %WalEx.Event{
      name: String.to_atom(table),
      type: :delete,
      source: source(table),
      old_record: record_map(record),
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now()),
      lsn: Keyword.get(opts, :lsn, {0, System.unique_integer([:positive])})
    }
  end

  defp source(table) do
    %WalEx.Event.Source{
      name: "WalEx",
      version: "test",
      db: "sacrum_test",
      schema: "public",
      table: table,
      columns: %{}
    }
  end

  defp changes(old_record, new_record) do
    old_record
    |> Map.keys()
    |> Enum.reduce(%{}, fn field, acc ->
      old_value = Map.get(old_record, field)
      new_value = Map.get(new_record, field)

      if old_value == new_value do
        acc
      else
        Map.put(acc, field, %{old_value: old_value, new_value: new_value})
      end
    end)
  end

  defp record_map(%schema{} = struct) when is_atom(schema) do
    fields = schema.__schema__(:fields)

    Map.take(struct, fields)
  end

  defp record_map(record) when is_map(record), do: record
end
