defmodule Sacrum.GenericResource do
  @moduledoc """
  A macro that generates user-scoped access functions for a schema module.

  This macro provides functions that always enforce user_id scoping, building
  queries dynamically from structured opts and always injecting
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
  - `:preloads` - A list of associations to preload (merged with runtime preloads)
  - `:default_order` - Default order_by clause (applied by list_by)

  ## Generated Functions

  - `get_by(user_id, opts)` → `{:ok, record} | {:error, :not_found}`
  - `list_by(user_id)` → `[record]`
  - `list_by(user_id, opts)` → `[record]`

  ## Opts Format

  Accepts structured opts with `:conditions` and `:preloads` keys:

      get_by(user_id, conditions: [id: id], preloads: [:sections])
      list_by(user_id, conditions: [project_id: pid], preloads: [:children])

  Also accepts flat keyword clauses for backward compatibility:

      get_by(user_id, id: id)
      list_by(user_id, project_id: pid)
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
      Retrieve a single record by user_id and opts.

      Always scopes to the given user_id. Merges runtime preloads with
      module-level preloads.
      Returns `{:ok, record}` or `{:error, :not_found}`.
      """
      def get_by(user_id, opts) when is_binary(user_id) and is_list(opts) do
        {conditions, runtime_preloads} = extract_opts(opts)
        all_preloads = merge_preloads(@preloads, runtime_preloads)

        query =
          from(s in Schema, where: s.user_id == ^user_id)
          |> apply_clauses(conditions)

        case Repo.one(query) do
          nil -> {:error, :not_found}
          record -> {:ok, apply_preloads(record, all_preloads)}
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

      Always scopes to the given user_id. Applies conditions, default ordering,
      and merges runtime preloads with module-level preloads.
      Returns a list of records.
      """
      def list_by(user_id, opts) when is_binary(user_id) and is_list(opts) do
        {conditions, runtime_preloads} = extract_opts(opts)
        all_preloads = merge_preloads(@preloads, runtime_preloads)

        query =
          from(s in Schema,
            where: s.user_id == ^user_id,
            order_by: @default_order
          )
          |> apply_clauses(conditions)
          |> apply_query_preloads(all_preloads)
          |> Repo.all()
      end

      defp extract_opts(opts) do
        if Keyword.keyword?(opts) and Keyword.has_key?(opts, :conditions) do
          {Keyword.get(opts, :conditions, []), Keyword.get(opts, :preloads, [])}
        else
          # Flat clauses (backward compat) — treat entire list as conditions
          {opts, []}
        end
      end

      defp apply_clauses(query, clauses) do
        Enum.reduce(clauses, query, fn
          {key, value}, q when is_atom(key) ->
            where(q, [s], field(s, ^key) == ^value)

          _clause, q ->
            q
        end)
      end

      defp merge_preloads(module_preloads, runtime_preloads) do
        (module_preloads ++ runtime_preloads) |> Enum.uniq()
      end

      defp apply_preloads(record, []), do: record
      defp apply_preloads(record, preloads), do: Repo.preload(record, preloads)

      defp apply_query_preloads(query, []), do: query
      defp apply_query_preloads(query, preloads), do: preload(query, ^preloads)
    end
  end
end
