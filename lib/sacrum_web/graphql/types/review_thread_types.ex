defmodule SacrumWeb.Graphql.Types.ReviewThreadTypes do
  @moduledoc "GraphQL queries and writes for machine-scoped review threads."

  use Absinthe.Schema.Notation

  alias Sacrum.Accounts.ReviewThreads
  alias SacrumWeb.Graphql.ChatResult

  object :review_thread_entry do
    field :thread_id, non_null(:uuid4)
    field :project_id, non_null(:uuid4)
    field :installation_id, non_null(:uuid4)
    field :revision, non_null(:integer)
    field :updated_at, non_null(:datetime)
    field :payload, non_null(:json)
  end

  object :review_thread_page do
    field :entries, non_null(list_of(non_null(:review_thread_entry)))
    field :next_cursor, :uuid4
  end

  object :review_thread_write do
    field :status, non_null(:string)
    field :entry, :review_thread_entry
  end

  object :review_thread_queries do
    field :review_threads, :review_thread_page do
      arg(:project_id, non_null(:uuid4))
      arg(:installation_id, non_null(:uuid4))
      arg(:after, :uuid4)
      arg(:limit, :integer, default_value: 100)

      resolve(fn args, %{context: %{current_user: user}} ->
        user.id
        |> ReviewThreads.list(
          args.project_id,
          args.installation_id,
          Map.get(args, :after),
          args.limit
        )
        |> ChatResult.format("review thread")
      end)
    end
  end

  object :review_thread_mutations do
    field :put_review_thread, :review_thread_write do
      arg(:project_id, non_null(:uuid4))
      arg(:installation_id, non_null(:uuid4))
      arg(:thread_id, non_null(:uuid4))
      arg(:expected_revision, non_null(:integer))
      arg(:mutation_id, non_null(:uuid4))
      arg(:payload, non_null(:json))

      resolve(fn args, %{context: %{current_user: user}} ->
        user.id
        |> ReviewThreads.put(
          args.project_id,
          args.installation_id,
          args.thread_id,
          args.expected_revision,
          args.mutation_id,
          args.payload
        )
        |> ChatResult.format("review thread")
      end)
    end
  end
end
