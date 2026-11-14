defmodule SacrumWeb.Graphql.Types.ChatCatalogTypes do
  use Absinthe.Schema.Notation
  alias Sacrum.Accounts.ChatCatalog
  alias Sacrum.Repo.Schemas.ChatCatalogEntry

  object :chat_installation do
    field :id, :uuid4
    field :user_id, :uuid4
  end

  object :chat_catalog_entry do
    field :chat_id, :string
    field :revision, :integer
    field :updated_at, :datetime

    field :status, :string do
      resolve(fn entry, _, _ -> {:ok, to_string(entry.status)} end)
    end

    field :payload, :json do
      resolve(fn entry, _, _ -> {:ok, ChatCatalogEntry.payload(entry)} end)
    end
  end

  object :chat_catalog_page do
    field :entries, list_of(:chat_catalog_entry)
    field :next_cursor, :string
  end

  object :chat_catalog_write do
    field :status, :string
    field :entry, :chat_catalog_entry
  end

  object :chat_catalog_queries do
    field :chat_catalog, :chat_catalog_page do
      arg(:project_id, non_null(:uuid4))
      arg(:installation_id, non_null(:uuid4))
      arg(:after, :string)
      arg(:limit, :integer, default_value: 100)

      arg(:include_completed, non_null(:boolean),
        default_value: false,
        description: "Include chats linked to tasks whose completed_at is set."
      )

      resolve(fn args, %{context: %{current_user: user}} ->
        ChatCatalog.list(
          user.id,
          args.project_id,
          args.installation_id,
          Map.get(args, :after),
          args.limit,
          args.include_completed
        )
      end)
    end
  end

  object :chat_catalog_mutations do
    field :register_chat_installation, :chat_installation do
      arg(:installation_id, non_null(:uuid4))

      resolve(fn args, %{context: %{current_user: user}} ->
        ChatCatalog.register(user.id, args.installation_id)
      end)
    end

    field :put_chat_catalog, :chat_catalog_write do
      arg(:project_id, non_null(:uuid4))
      arg(:installation_id, non_null(:uuid4))
      arg(:chat_id, non_null(:string))
      arg(:expected_revision, non_null(:integer))
      arg(:mutation_id, non_null(:uuid4))
      arg(:payload, non_null(:json))

      resolve(fn args, %{context: %{current_user: user}} ->
        ChatCatalog.put(
          user.id,
          args.project_id,
          args.installation_id,
          args.chat_id,
          args.expected_revision,
          args.mutation_id,
          args.payload
        )
      end)
    end
  end
end
