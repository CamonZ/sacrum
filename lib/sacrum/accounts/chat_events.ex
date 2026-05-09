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
  alias Sacrum.Repo.Schemas.ChatEvent

  @spec append(String.t(), String.t(), String.t(), map()) ::
          {:ok, ChatEvent.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def append(user_id, project_id, chat_session_id, attrs)
      when is_session_scope(user_id, project_id, chat_session_id) and is_attrs(attrs) do
    with {:ok, chat_session} <- ChatSessions.get_session(user_id, project_id, chat_session_id) do
      ChatEventsRepo.insert(chat_session, attrs)
    end
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
end
