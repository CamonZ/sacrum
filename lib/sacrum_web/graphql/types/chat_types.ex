defmodule SacrumWeb.Graphql.Types.ChatTypes do
  @moduledoc """
  GraphQL types and fields for the V0 live chat session API.
  """

  use Absinthe.Schema.Notation

  alias Sacrum.Accounts.{Artifacts, LiveChat}
  alias Sacrum.Chat.PublicEvents
  alias Sacrum.ChatSessions.Status, as: ChatSessionStatus
  alias SacrumWeb.Graphql.ChangesetErrors

  object :chat_session do
    field :id, :id
    field :project_id, :id

    field :status, :string do
      resolve(fn session, _args, _resolution ->
        {:ok, ChatSessionStatus.wire_value(session.status)}
      end)
    end

    field :session_kind, :string
    field :started_at, :datetime
    field :ended_at, :datetime
    field :stop_requested_at, :datetime
    field :public_metadata, :json
    field :inserted_at, :datetime
    field :updated_at, :datetime

    field :artifacts, list_of(:artifact) do
      resolve(fn session, _args, %{context: %{current_user: user}} ->
        {:ok, Artifacts.list_for_subject(user.id, session.project_id, "chat_session", session.id)}
      end)
    end

    field :messages, list_of(:chat_message) do
      arg(:limit, :integer)
      arg(:after, :datetime)

      resolve(fn session, args, %{context: %{current_user: user}} ->
        LiveChat.list_messages(user.id, session.project_id, session.id, list_opts(args))
      end)
    end

    field :events, list_of(:chat_event) do
      arg(:limit, :integer)
      arg(:after, :datetime)

      resolve(fn session, args, %{context: %{current_user: user}} ->
        LiveChat.list_public_events(user.id, session.project_id, session.id, list_opts(args))
      end)
    end
  end

  object :chat_message do
    field :id, :id
    field :project_id, :id
    field :chat_session_id, :id

    field :role, :string do
      resolve(fn message, _args, _resolution -> {:ok, wire_value(message.role)} end)
    end

    field :content, :string

    field :content_format, :string do
      resolve(fn message, _args, _resolution -> {:ok, wire_value(message.content_format)} end)
    end

    field :client_message_id, :string
    field :metadata, :json
    field :inserted_at, :datetime
    field :updated_at, :datetime
  end

  object :chat_event do
    field :id, :id
    field :project_id, :id
    field :chat_session_id, :id
    field :event_type, :string

    field :payload, :json do
      resolve(fn event, _args, _resolution -> {:ok, PublicEvents.graphql_payload(event)} end)
    end

    field :inserted_at, :datetime
  end

  object :delete_chat_session_payload do
    field :deleted_session_id, non_null(:id)
    field :success, non_null(:boolean)
  end

  object :chat_queries do
    field :chat_session, :chat_session do
      arg(:project_id, non_null(:uuid4))
      arg(:id, non_null(:uuid4))

      resolve(fn %{project_id: project_id, id: id}, %{context: %{current_user: user}} ->
        LiveChat.get_session(user.id, project_id, id)
      end)
    end

    field :chat_sessions, list_of(:chat_session) do
      arg(:project_id, non_null(:uuid4))
      arg(:limit, :integer)

      resolve(fn %{project_id: project_id} = args, %{context: %{current_user: user}} ->
        {:ok, LiveChat.list_sessions(user.id, project_id, list_opts(args))}
      end)
    end

    field :chat_messages, list_of(:chat_message) do
      arg(:project_id, non_null(:uuid4))
      arg(:chat_session_id, non_null(:uuid4))
      arg(:limit, :integer)
      arg(:after, :datetime)

      resolve(fn %{project_id: project_id, chat_session_id: chat_session_id} = args,
                 %{context: %{current_user: user}} ->
        LiveChat.list_messages(user.id, project_id, chat_session_id, list_opts(args))
      end)
    end

    field :chat_events, list_of(:chat_event) do
      arg(:project_id, non_null(:uuid4))
      arg(:chat_session_id, non_null(:uuid4))
      arg(:limit, :integer)
      arg(:after, :datetime)

      resolve(fn %{project_id: project_id, chat_session_id: chat_session_id} = args,
                 %{context: %{current_user: user}} ->
        LiveChat.list_public_events(user.id, project_id, chat_session_id, list_opts(args))
      end)
    end
  end

  object :chat_mutations do
    field :create_chat_session, :chat_session do
      arg(:project_id, non_null(:uuid4))
      arg(:session_kind, :string)
      arg(:public_metadata, :json)

      resolve(fn args, %{context: %{current_user: user}} ->
        project_id = Map.fetch!(args, :project_id)

        attrs =
          args
          |> Map.take([:session_kind, :public_metadata])
          |> reject_nil_values()

        user.id
        |> LiveChat.create_session(project_id, attrs)
        |> format_result()
      end)
    end

    field :send_chat_message, :chat_message do
      arg(:project_id, non_null(:uuid4))
      arg(:chat_session_id, non_null(:uuid4))
      arg(:content, non_null(:string))
      arg(:content_format, :string, default_value: "plain")
      arg(:client_message_id, :string)
      arg(:metadata, :json)

      resolve(fn %{project_id: project_id, chat_session_id: chat_session_id} = args,
                 %{context: %{current_user: user}} ->
        attrs =
          args
          |> Map.take([:content, :content_format, :client_message_id, :metadata])
          |> reject_nil_values()

        user.id
        |> LiveChat.send_message_and_start_runner(project_id, chat_session_id, attrs)
        |> format_result()
      end)
    end

    field :cancel_chat_session, :chat_session do
      arg(:project_id, non_null(:uuid4))
      arg(:chat_session_id, non_null(:uuid4))

      resolve(fn %{project_id: project_id, chat_session_id: chat_session_id},
                 %{context: %{current_user: user}} ->
        user.id
        |> LiveChat.cancel_session(project_id, chat_session_id)
        |> format_result()
      end)
    end

    field :delete_chat_session, :delete_chat_session_payload do
      arg(:project_id, non_null(:uuid4))
      arg(:chat_session_id, non_null(:uuid4))

      resolve(fn %{project_id: project_id, chat_session_id: chat_session_id},
                 %{context: %{current_user: user}} ->
        user.id
        |> LiveChat.delete_session(project_id, chat_session_id)
        |> delete_result()
        |> format_result()
      end)
    end
  end

  defp list_opts(args) do
    args
    |> Map.take([:limit, :after])
    |> reject_nil_values()
    |> Map.to_list()
  end

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp format_result({:error, %Ecto.Changeset{} = changeset}) do
    {:error, ChangesetErrors.format(changeset)}
  end

  defp format_result(result), do: result

  defp delete_result({:ok, session}) do
    {:ok, %{deleted_session_id: session.id, success: true}}
  end

  defp delete_result(result), do: result

  defp wire_value(value) when is_atom(value), do: Atom.to_string(value)
  defp wire_value(value), do: value
end
