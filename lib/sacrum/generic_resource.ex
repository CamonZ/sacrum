defmodule Sacrum.GenericResource do
  @moduledoc """
  A macro that generates user-scoped access functions for a schema module.

  This macro provides functions that always enforce user_id scoping, delegating
  to the corresponding repo module (which uses GenericRepo) for query building,
  preloading, and execution.

  ## Usage

      defmodule Sacrum.Accounts.Projects do
        use Sacrum.GenericResource,
          repo: Sacrum.Repo.Projects,
          preloads: [:tasks],
          default_order: [asc: :inserted_at]
      end

  ## Options

  - `:repo` (required) - The repo module (uses GenericRepo) to delegate to
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
    repo = Keyword.fetch!(opts, :repo)
    preloads = Keyword.get(opts, :preloads, [])
    default_order = Keyword.get(opts, :default_order, asc: :inserted_at)

    quote do
      alias unquote(repo), as: RepoModule

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

        RepoModule.get_by(
          conditions: [{:user_id, user_id} | conditions],
          preloads: all_preloads
        )
      end

      @doc """
      List all records for a user.

      Always scopes to the given user_id. Applies configured default ordering.
      Returns a list of records.
      """
      def list_by(user_id) when is_binary(user_id) do
        RepoModule.all(
          conditions: [user_id: user_id],
          preloads: @preloads,
          order_by: @default_order
        )
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

        RepoModule.all(
          conditions: [{:user_id, user_id} | conditions],
          preloads: all_preloads,
          order_by: @default_order
        )
      end

      defp extract_opts(opts) do
        if Keyword.keyword?(opts) and Keyword.has_key?(opts, :conditions) do
          {Keyword.get(opts, :conditions, []), Keyword.get(opts, :preloads, [])}
        else
          # Flat clauses (backward compat) — treat entire list as conditions
          {opts, []}
        end
      end

      defp merge_preloads(module_preloads, runtime_preloads) do
        Enum.uniq(module_preloads ++ runtime_preloads)
      end
    end
  end
end
