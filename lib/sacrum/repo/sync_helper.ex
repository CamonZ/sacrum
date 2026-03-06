defmodule Sacrum.Repo.SyncHelper do
  @moduledoc """
  Generic diff-and-sync helper for managing transition records.

  This module extracts the shared logic from Workflows.sync_transitions and
  WorkflowSteps.sync_transitions to avoid duplication. It handles:
  - Diffing incoming attrs against existing records
  - Building Ecto.Multi operations (insert, update, delete)
  - Executing the transaction atomically

  The caller provides a configuration that specifies:
  - How to uniquely identify records (the "target" key)
  - How to fetch the final synced records after the transaction
  """

  alias Ecto.Multi
  alias Sacrum.Repo

  @doc """
  Diffs and syncs incoming records against existing ones, executing all changes in a transaction.

  This function:
  1. Compares existing records (from DB) with incoming maps (from request)
  2. Determines which records to delete, insert, and update
  3. Builds an Ecto.Multi transaction
  4. Executes it atomically
  5. Fetches and returns the final synced records

  ## Parameters

  - `existing`: List of existing records from the database
  - `incoming_maps`: List of attribute maps from the request
  - `config`: Configuration map with keys:
    - `:target_key` - Atom key to uniquely identify targets (e.g., `:to_workflow_id` or `:to_step_id`)
    - `:to_delete_fn` - Function to identify records to delete
    - `:to_insert_fn` - Function to identify maps to insert
    - `:to_update_fn` - Function to identify pairs to update
    - `:build_changeset_fn` - Function that returns a changeset for inserts: `fn(map) -> changeset`
    - `:build_update_changeset_fn` - Function that returns a changeset for updates: `fn(existing, map) -> changeset`
    - `:fetch_final_fn` - Function to fetch final synced records: `fn() -> {:ok, records}` or `{:error, reason}`
    - `:delete_name_fn` - Optional function to generate delete operation name: `fn(record) -> name`. Defaults to `{:delete, record.id}`
    - `:insert_name_fn` - Optional function to generate insert operation name: `fn(map) -> name`. Defaults to `{:insert, target_id}`
    - `:update_name_fn` - Optional function to generate update operation name: `fn(map) -> name`. Defaults to `{:update, target_id}`

  ## Returns

  `{:ok, [synced_records]}` or `{:error, changeset}`

  ## Example (WorkflowTransitions)

  ```elixir
  SyncHelper.diff_and_sync(existing, incoming_maps, %{
    target_key: :to_workflow_id,
    to_delete_fn: fn existing, target_ids ->
      Enum.filter(existing, fn t -> not MapSet.member?(target_ids, t.to_workflow_id) end)
    end,
    to_insert_fn: fn incoming, existing_map ->
      Enum.filter(incoming, fn m -> not Map.has_key?(existing_map, m["to_workflow_id"]) end)
    end,
    to_update_fn: fn incoming, existing_map ->
      # ... logic to build update pairs
    end,
    build_changeset_fn: fn map -> WorkflowTransition.create_changeset(%WorkflowTransition{}, map) end,
    build_update_changeset_fn: fn existing, map ->
      Ecto.Changeset.change(existing, %{label: map["label"], target_step_id: map["target_step_id"]})
    end,
    fetch_final_fn: fn -> {:ok, Repo.WorkflowTransitions.all(conditions: [from_workflow_id: workflow.id], order_by: [asc: :inserted_at])} end
  })
  ```
  """
  def diff_and_sync(existing, incoming_maps, config)
      when is_list(existing) and is_list(incoming_maps) and is_map(config) do
    {to_delete, to_insert, to_update} = compute_diffs(existing, incoming_maps, config)
    name_fns = build_name_fns(config)

    multi =
      Multi.new()
      |> build_deletes(to_delete, name_fns.delete)
      |> build_inserts(to_insert, config[:build_changeset_fn], name_fns.insert)
      |> build_updates(to_update, config[:build_update_changeset_fn], name_fns.update)

    case Repo.transaction(multi) do
      {:ok, _} -> config[:fetch_final_fn].()
      {:error, _name, changeset, _changes} -> {:error, changeset}
    end
  end

  defp compute_diffs(existing, incoming_maps, config) do
    target_key = config[:target_key]

    existing_by_target =
      Map.new(existing, fn record ->
        {Map.fetch!(record, target_key), record}
      end)

    target_key_str = Atom.to_string(target_key)

    incoming_target_ids =
      MapSet.new(incoming_maps, fn map ->
        map[target_key_str] || map[target_key]
      end)

    {
      config[:to_delete_fn].(existing, incoming_target_ids),
      config[:to_insert_fn].(incoming_maps, existing_by_target),
      config[:to_update_fn].(incoming_maps, existing_by_target)
    }
  end

  defp build_name_fns(config) do
    target_key = config[:target_key]
    target_key_str = Atom.to_string(target_key)

    default_target_name = fn map ->
      map[target_key_str] || map[target_key]
    end

    %{
      delete: config[:delete_name_fn] || fn record -> {:delete, record.id} end,
      insert: config[:insert_name_fn] || fn map -> {:insert, default_target_name.(map)} end,
      update: config[:update_name_fn] || fn map -> {:update, default_target_name.(map)} end
    }
  end

  defp build_deletes(multi, records, name_fn) do
    Enum.reduce(records, multi, fn record, acc ->
      Multi.delete(acc, name_fn.(record), record)
    end)
  end

  defp build_inserts(multi, maps, changeset_fn, name_fn) do
    Enum.reduce(maps, multi, fn map, acc ->
      changeset = changeset_fn.(map)
      Multi.insert(acc, name_fn.(map), changeset)
    end)
  end

  defp build_updates(multi, pairs, changeset_fn, name_fn) do
    Enum.reduce(pairs, multi, fn {existing_rec, map}, acc ->
      changeset = changeset_fn.(existing_rec, map)
      Multi.update(acc, name_fn.(map), changeset)
    end)
  end
end
