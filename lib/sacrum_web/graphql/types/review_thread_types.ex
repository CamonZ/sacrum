defmodule SacrumWeb.Graphql.Types.ReviewThreadTypes do
  @moduledoc "GraphQL queries and writes for machine-scoped review threads."

  use Absinthe.Schema.Notation

  alias Sacrum.Accounts.ReviewThreads

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
        |> graphql_result()
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
        |> graphql_result()
      end)
    end
  end

  defp graphql_result({:ok, %{status: status} = write}),
    do: {:ok, %{write | status: Atom.to_string(status)}}

  defp graphql_result({:ok, _} = result), do: result

  defp graphql_result({:error, :invalid_payload}),
    do: {:error, %{message: "Invalid review thread input", code: "invalid_payload"}}

  defp graphql_result({:error, :not_found}),
    do: {:error, %{message: "Review thread or its scope was not found", code: "not_found"}}
end
