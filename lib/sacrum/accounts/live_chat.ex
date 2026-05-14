defmodule Sacrum.Accounts.LiveChat do
  @moduledoc """
  Public V0 live chat operations used by GraphQL.

  This layer composes chat sessions, messages, and persisted public chat events.
  It intentionally stays session-first and does not create chat runs, artifacts,
  task links, or runner behavior.
  """

  alias Sacrum.Accounts.{ChatEvents, ChatMessages, ChatSessions}
  alias Sacrum.Chat.{Inference, InferenceEvents, PublicEvents}
  alias Sacrum.ChatSessions.Status, as: ChatSessionStatus
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{ChatMessage, ChatSession}

  @spec create_session(String.t(), String.t(), map()) ::
          {:ok, ChatSession.t()} | {:error, term()}
  def create_session(user_id, project_id, attrs \\ %{}) when is_map(attrs) do
    transaction_result(fn ->
      with {:ok, session} <- ChatSessions.insert(user_id, project_id, attrs),
           {:ok, event} <-
             ChatEvents.append_to_session(
               session,
               PublicEvents.session_created_attrs(session)
             ) do
        {session, event}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec send_message(String.t(), String.t(), String.t(), map()) ::
          {:ok, ChatMessage.t()} | {:error, term()}
  def send_message(user_id, project_id, chat_session_id, attrs) when is_map(attrs) do
    attrs =
      attrs
      |> put_default(:role, "role", :user)
      |> put_default(:content_format, "content_format", ChatMessage.default_content_format())

    transaction_result(fn ->
      with {:ok, session} <- ChatSessions.get_session(user_id, project_id, chat_session_id),
           {:ok, message} <- ChatMessages.append_to_session(session, attrs),
           {:ok, event} <-
             ChatEvents.append_to_session(
               session,
               PublicEvents.message_created_attrs(message)
             ) do
        {message, event}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec run_inference(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, ChatMessage.t()} | {:error, term()}
  def run_inference(user_id, project_id, chat_session_id, opts \\ []) when is_list(opts) do
    with {:ok, session} <- ChatSessions.get_session(user_id, project_id, chat_session_id),
         {:ok, messages} <- ChatMessages.list_for_session(session, []),
         {:ok, inference_result} <- Inference.generate(messages, opts) do
      persist_assistant_result(session, inference_result)
    end
  end

  @spec cancel_session(String.t(), String.t(), String.t()) ::
          {:ok, ChatSession.t()} | {:error, term()}
  def cancel_session(user_id, project_id, chat_session_id) do
    transaction_result(fn ->
      with {:ok, session} <- ChatSessions.get_session(user_id, project_id, chat_session_id),
           :ok <- ensure_stoppable(session),
           {:ok, updated_session} <-
             ChatSessions.update_session(session, %{
               status: :cancelled,
               stop_requested_at: session.stop_requested_at || DateTime.utc_now()
             }),
           {:ok, event} <-
             ChatEvents.append_to_session(
               updated_session,
               PublicEvents.session_updated_attrs(updated_session)
             ) do
        {updated_session, event}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec delete_session(String.t(), String.t(), String.t()) ::
          {:ok, ChatSession.t()} | {:error, term()}
  def delete_session(user_id, project_id, chat_session_id) do
    ChatSessions.delete_session(user_id, project_id, chat_session_id)
  end

  @spec get_session(String.t(), String.t(), String.t()) ::
          {:ok, ChatSession.t()} | {:error, term()}
  def get_session(user_id, project_id, chat_session_id) do
    ChatSessions.get_session(user_id, project_id, chat_session_id)
  end

  @spec list_sessions(String.t(), String.t(), keyword()) :: [ChatSession.t()]
  def list_sessions(user_id, project_id, opts \\ []) do
    ChatSessions.list_sessions(user_id, project_id, opts)
  end

  @spec list_messages(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [ChatMessage.t()]} | {:error, term()}
  def list_messages(user_id, project_id, chat_session_id, opts \\ []) do
    ChatMessages.list_for_session(user_id, project_id, chat_session_id, opts)
  end

  @spec list_public_events(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def list_public_events(user_id, project_id, chat_session_id, opts \\ []) do
    ChatEvents.list_public_for_session(user_id, project_id, chat_session_id, opts)
  end

  defp transaction_result(fun) do
    case Repo.transaction(fun) do
      {:ok, {result, _event}} ->
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_assistant_result(%ChatSession{} = session, %Inference.Result{} = inference_result) do
    transaction_result(fn ->
      with {:ok, message} <-
             ChatMessages.append_to_session(
               session,
               InferenceEvents.assistant_message_attrs(inference_result)
             ),
           {:ok, public_event} <-
             ChatEvents.append_to_session(
               session,
               PublicEvents.message_created_attrs(message)
             ),
           {:ok, _internal_event} <-
             ChatEvents.append_to_session(
               session,
               InferenceEvents.inference_completed_attrs(message, inference_result)
             ) do
        {message, public_event}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp ensure_stoppable(%ChatSession{status: status}) do
    if ChatSessionStatus.stoppable?(status) do
      :ok
    else
      {:error, "Cannot cancel chat session with status #{ChatSessionStatus.wire_value(status)}"}
    end
  end

  defp put_default(attrs, atom_key, string_key, value) do
    if Map.has_key?(attrs, atom_key) or Map.has_key?(attrs, string_key) do
      attrs
    else
      Map.put(attrs, atom_key, value)
    end
  end
end
