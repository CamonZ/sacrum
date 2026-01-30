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
  - `get!(id)` → record or raises
  - `get_by(clauses)` → `{:ok, record} | {:error, :not_found}`
  - `all()` → `[record]`
  - `all(queryable)` → `[record]`
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

      Returns `{:ok, record}` or `{:error, :not_found}`.
      """
      def get(id) do
        case Repo.get(Schema, id) do
          nil -> {:error, :not_found}
          record -> {:ok, record}
        end
      end

      defoverridable get: 1

      @doc """
      Retrieve a single record by primary key, raising if not found.
      """
      def get!(id) do
        Repo.get!(Schema, id)
      end

      defoverridable get!: 1

      @doc """
      Retrieve a single record by key-value clauses.

      Returns `{:ok, record}` or `{:error, :not_found}`.
      """
      def get_by(clauses) do
        case Repo.get_by(Schema, clauses) do
          nil -> {:error, :not_found}
          record -> {:ok, record}
        end
      end

      defoverridable get_by: 1

      @doc """
      Retrieve all records of this schema.
      """
      def all do
        Repo.all(Schema)
      end

      defoverridable all: 0

      @doc """
      Retrieve all records matching a queryable.
      """
      def all(queryable) do
        Repo.all(queryable)
      end

      defoverridable all: 1

      @doc """
      Return a base query for this schema.
      """
      def query do
        from(Schema)
      end

      defoverridable query: 0

      @doc """
      Count all records of this schema.
      """
      def count do
        from(s in Schema, select: count(s.id))
        |> Repo.one()
      end

      defoverridable count: 0

      @doc """
      Count records matching a queryable.
      """
      def count(queryable) do
        from(s in queryable, select: count(s.id))
        |> Repo.one()
      end

      defoverridable count: 1

      @doc """
      Check if a record exists by primary key.
      """
      def exists?(id) do
        from(s in Schema, where: s.id == ^id, select: true)
        |> Repo.exists?()
      end

      defoverridable exists?: 1

      @doc """
      Insert a changeset.

      Returns `{:ok, record}` or `{:error, changeset}`.
      """
      def insert(changeset) do
        Repo.insert(changeset)
      end

      defoverridable insert: 1

      @doc """
      Update a changeset.

      Returns `{:ok, record}` or `{:error, changeset}`.
      """
      def update(changeset) do
        Repo.update(changeset)
      end

      defoverridable update: 1

      @doc """
      Delete a record.

      Returns `{:ok, record}` or `{:error, changeset}`.
      """
      def delete(record) do
        Repo.delete(record)
      end

      defoverridable delete: 1
    end
  end
end
