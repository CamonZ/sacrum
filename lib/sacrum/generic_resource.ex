defmodule Sacrum.GenericResource do
  @moduledoc """
  A macro that generates user-scoped access functions for a schema module.

  This macro provides functions that always enforce user_id scoping, building
  queries dynamically from keyword list clauses and always injecting
  `WHERE user_id = ?`. Useful for resource modules that need to scope all
  operations to the current user.

  ## Usage

      defmodule Sacrum.Accounts.Projects do
        use Sacrum.GenericResource,
          schema: Sacrum.Repo.Schemas.Project,
          preloads: [:tasks],
          default_order: [asc: :inserted_at]
      end

  ## Options

  - `:schema` (required) - The schema module to scope
  - `:preloads` - A list of associations to preload (applied by get_by)
  - `:default_order` - Default order_by clause (applied by list_by)

  ## Generated Functions

  - `get_by(user_id, clauses)` → `{:ok, record} | {:error, :not_found}`
  - `list_by(user_id)` → `[record]`
  - `list_by(user_id, clauses)` → `[record]`
  """

  defmacro __using__(opts) do
    schema = Keyword.fetch!(opts, :schema)
    preloads = Keyword.get(opts, :preloads, [])
    default_order = Keyword.get(opts, :default_order, asc: :inserted_at)

    quote do
      import Ecto.Query
      alias Sacrum.Repo
      alias unquote(schema), as: Schema

      @preloads unquote(preloads)
      @default_order unquote(default_order)

      @doc """
      Retrieve a single record by user_id and clauses.

      Always scopes to the given user_id. Applies configured preloads.
      Returns `{:ok, record}` or `{:error, :not_found}`.
      """
      def get_by(user_id, clauses) when is_binary(user_id) and is_list(clauses) do
        query =
          from(s in Schema, where: s.user_id == ^user_id)
          |> apply_clauses(clauses)

        case Repo.one(query) do
          nil -> {:error, :not_found}
          record -> {:ok, maybe_preload(record)}
        end
      end

      @doc """
      List all records for a user.

      Always scopes to the given user_id. Applies configured default ordering.
      Returns a list of records.
      """
      def list_by(user_id) when is_binary(user_id) do
        from(s in Schema,
          where: s.user_id == ^user_id,
          order_by: @default_order
        )
        |> Repo.all()
      end

      @doc """
      List records for a user with optional filters.

      Always scopes to the given user_id. Applies clauses, default ordering,
      and configured preloads. Returns a list of records.
      """
      def list_by(user_id, clauses) when is_binary(user_id) and is_list(clauses) do
        from(s in Schema,
          where: s.user_id == ^user_id,
          order_by: @default_order
        )
        |> apply_clauses(clauses)
        |> Repo.all()
      end

      defp apply_clauses(query, clauses) do
        Enum.reduce(clauses, query, fn
          {key, value}, q when is_atom(key) ->
            where(q, [s], field(s, ^key) == ^value)

          _clause, q ->
            q
        end)
      end

      defp maybe_preload(record) do
        if Enum.empty?(@preloads) do
          record
        else
          Repo.preload(record, @preloads)
        end
      end
    end
  end
end
