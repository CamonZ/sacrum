defmodule Sacrum.GenericRepo do
  @moduledoc """
  A macro that generates base Ecto operations for a schema module.

  This macro provides foundational CRUD operations that work with any schema,
  without user scoping or business logic. All generated functions are marked
  as defoverridable, allowing modules to customize behavior as needed.

  ## Usage

      defmodule Sacrum.Repo.Projects do
        use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.Project
      end

  ## Generated Functions

  - `get(id)` → `{:ok, record} | {:error, :not_found}`
  - `get(id, opts)` → `{:ok, record} | {:error, :not_found}` (with preloads)
  - `get!(id)` → record or raises
  - `get_by(opts)` → `{:ok, record} | {:error, :not_found}` (conditions + preloads)
  - `all()` → `[record]`
  - `all(opts)` → `[record]` (conditions + preloads, or queryable)
  - `query()` → `Ecto.Query.t()`
  - `count()` / `count(queryable)` → integer
  - `exists?(id)` → boolean
  - `insert(changeset)` → `{:ok, record} | {:error, changeset}`
  - `update(changeset)` → `{:ok, record} | {:error, changeset}`
  - `delete(record)` → `{:ok, record} | {:error, changeset}`
  """

  defmacro __using__(opts) do
    schema = Keyword.fetch!(opts, :schema)

    quote do
      import Ecto.Query
      alias Sacrum.Repo
      alias unquote(schema), as: Schema

      @doc """
      Retrieve a single record by primary key.

      Accepts optional keyword opts:
        - `:preloads` - list of associations to preload

      Returns `{:ok, record}` or `{:error, :not_found}`.
      """
      def get(id, opts \\ []) do
        case Repo.get(Schema, id) do
          nil -> {:error, :not_found}
          record -> {:ok, apply_preloads(record, Keyword.get(opts, :preloads, []))}
        end
      end

      defoverridable get: 1, get: 2

      @doc """
      Retrieve a single record by primary key, raising if not found.
      """
      def get!(id), do: Repo.get!(Schema, id)

      defoverridable get!: 1

      @doc """
      Retrieve a single record by structured opts or flat clauses.

      Structured opts:
        - `:conditions` - keyword list of field/value pairs for WHERE clauses
        - `:preloads` - list of associations to preload

      Also accepts flat keyword clauses for backward compatibility:
        `get_by(short_id: "abc")` is equivalent to `get_by(conditions: [short_id: "abc"])`

      Returns `{:ok, record}` or `{:error, :not_found}`.
      """
      def get_by(opts) do
        {conditions, preloads, _order_by} = extract_opts(opts)
        query = apply_conditions(from(s in Schema), conditions)

        case Repo.one(query) do
          nil -> {:error, :not_found}
          record -> {:ok, apply_preloads(record, preloads)}
        end
      end

      defoverridable get_by: 1

      @doc """
      Retrieve all records of this schema.
      """
      def all, do: Repo.all(Schema)

      defoverridable all: 0

      @doc """
      Retrieve all records matching a queryable or structured opts.

      When passed a keyword list with `:conditions`, builds a query with
      conditions and preloads. Otherwise treats the argument as a queryable.
      """
      def all(opts_or_queryable) do
        if Keyword.keyword?(opts_or_queryable) and
             Keyword.has_key?(opts_or_queryable, :conditions) do
          {conditions, preloads, order_by} = extract_opts(opts_or_queryable)

          Schema
          |> apply_conditions(conditions)
          |> apply_order_by(order_by)
          |> apply_query_preloads(preloads)
          |> Repo.all()
        else
          Repo.all(opts_or_queryable)
        end
      end

      defoverridable all: 1

      @doc """
      Return a base query for this schema.
      """
      def query, do: from(Schema)

      defoverridable query: 0

      @doc """
      Count all records of this schema.
      """
      def count, do: Repo.one(from(s in Schema, select: count(s.id)))

      defoverridable count: 0

      @doc """
      Count records matching a queryable.
      """
      def count(queryable), do: Repo.one(from(s in queryable, select: count(s.id)))

      defoverridable count: 1

      @doc """
      Check if a record exists by primary key.
      """
      def exists?(id), do: Repo.exists?(from(s in Schema, where: s.id == ^id, select: true))

      defoverridable exists?: 1

      @doc """
      Insert a changeset.

      Returns `{:ok, record}` or `{:error, changeset}`.
      """
      def insert(changeset), do: Repo.insert(changeset)

      defoverridable insert: 1

      @doc """
      Update a changeset.

      Returns `{:ok, record}` or `{:error, changeset}`.
      """
      def update(changeset), do: Repo.update(changeset)

      defoverridable update: 1

      @doc """
      Delete a record.

      Returns `{:ok, record}` or `{:error, changeset}`.
      """
      def delete(record), do: Repo.delete(record)

      defoverridable delete: 1

      # -- Private helpers for composable opts --

      defp extract_opts(opts) do
        if Keyword.keyword?(opts) and Keyword.has_key?(opts, :conditions) do
          {Keyword.get(opts, :conditions, []), Keyword.get(opts, :preloads, []),
           Keyword.get(opts, :order_by, [])}
        else
          {opts, [], []}
        end
      end

      defp apply_conditions(query, []), do: query

      defp apply_conditions(query, conditions) do
        Enum.reduce(conditions, query, fn {key, value}, q ->
          where(q, [s], field(s, ^key) == ^value)
        end)
      end

      defp apply_preloads(record, []), do: record
      defp apply_preloads(record, preloads), do: Repo.preload(record, preloads)

      defp apply_query_preloads(query, []), do: query

      defp apply_query_preloads(query, preloads) do
        Enum.reduce(preloads, query, fn assoc, q ->
          q
          |> join(:left, [s], a in assoc(s, ^assoc), as: ^assoc)
          |> preload([{^assoc, a}], [{^assoc, a}])
        end)
      end

      defp apply_order_by(query, []), do: query
      defp apply_order_by(query, order_by), do: order_by(query, ^order_by)
    end
  end
end
