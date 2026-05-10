defmodule Sacrum.Chat.PublicEvents do
  @moduledoc """
  Builds the persisted public chat event payloads used by GraphQL and channels.

  Public channel events must be projected from `chat_events.public_payload`; this
  module keeps the persisted payload and channel payload shape in one place.
  """

  alias Sacrum.ChatSessions.Status, as: ChatSessionStatus
  alias Sacrum.Repo.Schemas.{ChatEvent, ChatMessage, ChatSession}

  @session_created "chat_session_created"
  @session_updated "chat_session_updated"
  @message_created "chat_message_created"
  @generic_event_created "chat_event_created"

  @known_event_types [@session_created, @session_updated, @message_created]
  @channel_event_names [
    @session_created,
    @session_updated,
    @message_created,
    @generic_event_created
  ]

  @session_keys [
    {"id", :id},
    {"project_id", :project_id},
    {"status", :status},
    {"session_kind", :session_kind},
    {"started_at", :started_at},
    {"ended_at", :ended_at},
    {"stop_requested_at", :stop_requested_at},
    {"public_metadata", :public_metadata},
    {"inserted_at", :inserted_at},
    {"updated_at", :updated_at}
  ]
  @message_keys [
    {"id", :id},
    {"project_id", :project_id},
    {"chat_session_id", :chat_session_id},
    {"role", :role},
    {"content", :content},
    {"content_format", :content_format},
    {"client_message_id", :client_message_id},
    {"metadata", :metadata},
    {"inserted_at", :inserted_at},
    {"updated_at", :updated_at}
  ]

  @spec channel_event_names() :: [String.t()]
  def channel_event_names, do: @channel_event_names

  @spec session_created_attrs(ChatSession.t()) :: map()
  def session_created_attrs(%ChatSession{} = session) do
    public_event_attrs(@session_created, session_payload(session))
  end

  @spec session_updated_attrs(ChatSession.t()) :: map()
  def session_updated_attrs(%ChatSession{} = session) do
    public_event_attrs(@session_updated, session_payload(session))
  end

  @spec message_created_attrs(ChatMessage.t()) :: map()
  def message_created_attrs(%ChatMessage{} = message) do
    public_event_attrs(@message_created, message_payload(message))
  end

  @spec channel_event(ChatEvent.t() | map()) :: {:ok, String.t(), map()} | :ignore
  def channel_event(%ChatEvent{} = event), do: channel_event(Map.from_struct(event))

  def channel_event(%{visibility: visibility} = event) when visibility in [:public, "public"] do
    event_type = to_string(Map.fetch!(event, :event_type))
    payload = Map.get(event, :public_payload) || %{}

    if event_type in @known_event_types do
      {:ok, event_type, known_channel_payload(event_type, payload)}
    else
      {:ok, @generic_event_created, generic_channel_payload(event, payload)}
    end
  end

  def channel_event(_event), do: :ignore

  @spec graphql_payload(ChatEvent.t() | map()) :: map()
  def graphql_payload(%ChatEvent{public_payload: payload}), do: payload || %{}
  def graphql_payload(%{public_payload: payload}), do: payload || %{}
  def graphql_payload(%{"public_payload" => payload}), do: payload || %{}
  def graphql_payload(_event), do: %{}

  @spec session_payload(ChatSession.t()) :: map()
  def session_payload(%ChatSession{} = session) do
    %{
      "id" => session.id,
      "project_id" => session.project_id,
      "status" => ChatSessionStatus.wire_value(session.status),
      "session_kind" => session.session_kind,
      "started_at" => iso8601(session.started_at),
      "ended_at" => iso8601(session.ended_at),
      "stop_requested_at" => iso8601(session.stop_requested_at),
      "public_metadata" => session.public_metadata || %{},
      "inserted_at" => iso8601(session.inserted_at),
      "updated_at" => iso8601(session.updated_at)
    }
  end

  @spec message_payload(ChatMessage.t()) :: map()
  def message_payload(%ChatMessage{} = message) do
    %{
      "id" => message.id,
      "project_id" => message.project_id,
      "chat_session_id" => message.chat_session_id,
      "role" => wire_value(message.role),
      "content" => message.content,
      "content_format" => wire_value(message.content_format),
      "client_message_id" => message.client_message_id,
      "metadata" => message.metadata || %{},
      "inserted_at" => iso8601(message.inserted_at),
      "updated_at" => iso8601(message.updated_at)
    }
  end

  @spec event_type(
          :session_created
          | :session_updated
          | :message_created
          | :generic_event_created
        ) ::
          String.t()
  def event_type(:session_created), do: @session_created
  def event_type(:session_updated), do: @session_updated
  def event_type(:message_created), do: @message_created
  def event_type(:generic_event_created), do: @generic_event_created

  defp public_event_attrs(event_type, payload) do
    %{
      event_type: event_type,
      visibility: :public,
      public_payload: payload,
      internal_payload: %{}
    }
  end

  defp known_channel_payload(event_type, payload)
       when event_type in [@session_created, @session_updated] do
    atomize_known_payload(payload, @session_keys)
  end

  defp known_channel_payload(@message_created, payload) do
    atomize_known_payload(payload, @message_keys)
  end

  defp generic_channel_payload(event, payload) do
    %{
      id: get_value(event, :id),
      project_id: get_value(event, :project_id),
      chat_session_id: get_value(event, :chat_session_id),
      event_type: get_value(event, :event_type),
      payload: payload,
      inserted_at: iso8601(get_value(event, :inserted_at))
    }
  end

  defp atomize_known_payload(payload, keys) do
    Map.new(keys, fn {string_key, atom_key} ->
      {atom_key, get_known_value(payload, string_key, atom_key)}
    end)
  end

  defp get_known_value(map, string_key, atom_key) do
    cond do
      Map.has_key?(map, string_key) -> Map.fetch!(map, string_key)
      Map.has_key?(map, atom_key) -> Map.fetch!(map, atom_key)
      true -> nil
    end
  end

  defp get_value(map, key) when is_atom(key) do
    cond do
      Map.has_key?(map, key) -> Map.fetch!(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.fetch!(map, Atom.to_string(key))
      true -> nil
    end
  end

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(nil), do: nil
  defp iso8601(value), do: value

  defp wire_value(value) when is_atom(value), do: Atom.to_string(value)
  defp wire_value(value), do: value
end
