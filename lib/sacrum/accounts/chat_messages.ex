defmodule Sacrum.Accounts.ChatMessages do
  @moduledoc """
  User- and project-scoped helpers for public chat transcript messages.
  """

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.ChatMessages,
    preloads: [],
    default_order: [asc: :inserted_at]

  import Sacrum.Chat.Guards

  alias Sacrum.Accounts.ChatSessions
  alias Sacrum.Repo.ChatMessages, as: ChatMessagesRepo
  alias Sacrum.Repo.Schemas.ChatMessage

  @spec append(String.t(), String.t(), String.t(), map()) ::
          {:ok, ChatMessage.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def append(user_id, project_id, chat_session_id, attrs)
      when is_session_scope(user_id, project_id, chat_session_id) and is_attrs(attrs) do
    with {:ok, chat_session} <- ChatSessions.get_session(user_id, project_id, chat_session_id) do
      ChatMessagesRepo.insert(chat_session, attrs)
    end
  end

  @spec list_for_session(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [ChatMessage.t()]} | {:error, :not_found}
  def list_for_session(user_id, project_id, chat_session_id, opts \\ [])
      when is_session_scope(user_id, project_id, chat_session_id) and is_options(opts) do
    with {:ok, chat_session} <- ChatSessions.get_session(user_id, project_id, chat_session_id) do
      {:ok, ChatMessagesRepo.list_for_session(chat_session, opts)}
    end
  end
end
