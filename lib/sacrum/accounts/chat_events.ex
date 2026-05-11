defmodule Sacrum.Accounts.ChatEvents do
  @moduledoc """
  User- and project-scoped helpers for V0 chat events.

  Public read helpers intentionally return projection maps for public events
  and omit internal payloads.
  """

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.ChatEvents,
    preloads: [],
    default_order: [asc: :inserted_at]

  import Sacrum.Chat.Guards

  alias Sacrum.Accounts.ChatSessions
  alias Sacrum.Repo.ChatEvents, as: ChatEventsRepo
  alias Sacrum.Repo.Schemas.{ChatEvent, ChatSession}

  @spec append(String.t(), String.t(), String.t(), map()) ::
          {:ok, ChatEvent.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def append(user_id, project_id, chat_session_id, attrs)
      when is_session_scope(user_id, project_id, chat_session_id) and is_attrs(attrs) do
    with {:ok, chat_session} <- ChatSessions.get_session(user_id, project_id, chat_session_id) do
      append_to_session(chat_session, attrs)
    end
  end

  @spec append_to_session(Sacrum.Repo.Schemas.ChatSession.t(), map()) ::
          {:ok, ChatEvent.t()} | {:error, Ecto.Changeset.t()}
  def append_to_session(%Sacrum.Repo.Schemas.ChatSession{} = chat_session, attrs)
      when is_attrs(attrs) do
    ChatEventsRepo.insert(chat_session, attrs)
  end

  @spec list_public_for_session(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, :not_found}
  def list_public_for_session(user_id, project_id, chat_session_id, opts \\ [])
      when is_session_scope(user_id, project_id, chat_session_id) and is_options(opts) do
    with {:ok, chat_session} <- ChatSessions.get_session(user_id, project_id, chat_session_id) do
      events = ChatEventsRepo.list_public_for_session(chat_session, opts)
      {:ok, events}
    end
  end

  @spec get_by_type(ChatSession.t(), String.t(), :public | :internal) ::
          {:ok, ChatEvent.t()} | {:error, :not_found}
  def get_by_type(%ChatSession{} = chat_session, event_type, visibility)
      when is_binary(event_type) and visibility in [:public, :internal] do
    ChatEventsRepo.get_by_type(chat_session, event_type, visibility)
  end

  @spec get_message_created_for_message(ChatSession.t(), String.t()) ::
          {:ok, ChatEvent.t()} | {:error, :not_found}
  def get_message_created_for_message(%ChatSession{} = chat_session, message_id)
      when is_binary(message_id) do
    ChatEventsRepo.get_message_created_for_message(chat_session, message_id)
  end
end
