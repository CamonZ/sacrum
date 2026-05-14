defmodule Sacrum.Accounts.ChatSessions do
  @moduledoc """
  User- and project-scoped helpers for V0 live chat sessions.
  """

  use Sacrum.GenericResource,
    repo: Sacrum.Repo.ChatSessions,
    preloads: [],
    default_order: [desc: :inserted_at]

  import Sacrum.Chat.Guards

  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo.ChatSessions, as: ChatSessionsRepo
  alias Sacrum.Repo.Schemas.ChatSession

  @spec insert(String.t(), String.t(), map()) ::
          {:ok, ChatSession.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def insert(user_id, project_id, attrs \\ %{})
      when is_user_project_scope(user_id, project_id) and is_attrs(attrs) do
    with {:ok, _project} <- Projects.get_by(user_id, conditions: [id: project_id]) do
      ChatSessionsRepo.insert(user_id, project_id, attrs)
    end
  end

  @spec get_session(String.t(), String.t(), String.t()) ::
          {:ok, ChatSession.t()} | {:error, :not_found}
  def get_session(user_id, project_id, chat_session_id)
      when is_session_scope(user_id, project_id, chat_session_id) do
    get_by(user_id, conditions: [id: chat_session_id, project_id: project_id])
  end

  @spec list_sessions(String.t(), String.t(), keyword()) :: [ChatSession.t()]
  def list_sessions(user_id, project_id, opts \\ [])
      when is_user_project_scope(user_id, project_id) and is_options(opts) do
    ChatSessionsRepo.list_for_project(user_id, project_id, opts)
  end

  @spec update_session(String.t(), String.t(), String.t(), map()) ::
          {:ok, ChatSession.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def update_session(user_id, project_id, chat_session_id, attrs)
      when is_session_scope(user_id, project_id, chat_session_id) and is_attrs(attrs) do
    with {:ok, chat_session} <- get_session(user_id, project_id, chat_session_id) do
      ChatSessionsRepo.update(chat_session, attrs)
    end
  end

  @spec update_session(ChatSession.t(), map()) ::
          {:ok, ChatSession.t()} | {:error, Ecto.Changeset.t()}
  def update_session(%ChatSession{} = chat_session, attrs) when is_attrs(attrs) do
    ChatSessionsRepo.update(chat_session, attrs)
  end

  @spec delete_session(String.t(), String.t(), String.t()) ::
          {:ok, ChatSession.t()} | {:error, :not_found}
  def delete_session(user_id, project_id, chat_session_id)
      when is_session_scope(user_id, project_id, chat_session_id) do
    ChatSessionsRepo.delete_session(user_id, project_id, chat_session_id)
  end

  @spec transition_status(String.t(), String.t(), String.t(), atom() | String.t()) ::
          {:ok, ChatSession.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def transition_status(user_id, project_id, chat_session_id, status)
      when is_session_scope(user_id, project_id, chat_session_id) do
    update_session(user_id, project_id, chat_session_id, %{status: status})
  end
end
