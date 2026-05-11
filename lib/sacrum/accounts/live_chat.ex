defmodule Sacrum.Accounts.LiveChat do
  @moduledoc """
  Public V0 live chat operations used by GraphQL.

  This layer composes chat sessions, messages, persisted public chat events, and
  the async inference trigger for user messages. Inference work is coordinated by
  `Sacrum.Chat.InferenceCoordinator` so provider latency stays outside the
  message mutation path.
  """

  alias Sacrum.Accounts.{ChatEvents, ChatMessages, ChatSessions}
  alias Sacrum.Chat.{Inference, InferenceCoordinator, InferenceEvents, PublicEvents}
  alias Sacrum.ChatSessions.Status, as: ChatSessionStatus
  alias Sacrum.Repo
  alias Sacrum.Repo.Broadcaster
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

    case append_user_message(user_id, project_id, chat_session_id, attrs) do
      {:ok, {%ChatMessage{} = message, %ChatSession{} = session}} ->
        maybe_schedule_inference(message, session, user_id, project_id, chat_session_id)
        {:ok, message}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec run_inference(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, ChatMessage.t()} | {:error, term()}
  def run_inference(user_id, project_id, chat_session_id, opts \\ []) when is_list(opts) do
    with {:ok, session} <- ChatSessions.get_session(user_id, project_id, chat_session_id) do
      run_inference_for_session(session, opts)
    end
  end

  @doc false
  @spec run_inference_for_session(ChatSession.t(), keyword()) ::
          {:ok, ChatMessage.t()} | {:error, term()}
  def run_inference_for_session(%ChatSession{} = session, opts \\ []) when is_list(opts) do
    with :ok <- ensure_runnable(session),
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

  @spec get_session(String.t(), String.t(), String.t()) ::
          {:ok, ChatSession.t()} | {:error, term()}
  def get_session(user_id, project_id, chat_session_id) do
    ChatSessions.get_session(user_id, project_id, chat_session_id)
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
      {:ok, {result, event}} ->
        Broadcaster.broadcast_chat_event({:ok, event})
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp append_user_message(user_id, project_id, chat_session_id, attrs) do
    transaction_result(fn ->
      with {:ok, session} <- ChatSessions.get_session(user_id, project_id, chat_session_id),
           {:ok, message} <- ChatMessages.append_to_session(session, attrs),
           {:ok, event} <-
             ChatEvents.append_to_session(
               session,
               PublicEvents.message_created_attrs(message)
             ) do
        {{message, session}, event}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp persist_assistant_result(%ChatSession{} = session, %Inference.Result{} = inference_result) do
    transaction_result(fn ->
      with {:ok, message} <-
             ChatMessages.append_to_session(
               session,
               assistant_message_attrs(inference_result)
             ),
           {:ok, public_event} <-
             ChatEvents.append_to_session(
               session,
               PublicEvents.message_created_attrs(message)
             ),
           {:ok, _internal_event} <-
             ChatEvents.append_to_session(
               session,
               InferenceEvents.completed_attrs(message, inference_result)
             ) do
        {message, public_event}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp assistant_message_attrs(%Inference.Result{} = inference_result) do
    %{
      role: :assistant,
      content: inference_result.content,
      content_format: inference_result.content_format,
      metadata: inference_result.public_metadata
    }
  end

  defp maybe_schedule_inference(
         %ChatMessage{role: :user},
         %ChatSession{} = session,
         user_id,
         project_id,
         chat_session_id
       ) do
    with true <- async_inference_enabled?(),
         :ok <- ensure_runnable(session) do
      InferenceCoordinator.enqueue(user_id, project_id, chat_session_id, async_inference_opts())
    else
      false -> :ok
      {:error, {:chat_session_not_runnable, _status}} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp maybe_schedule_inference(_message, _session, _user_id, _project_id, _chat_session_id),
    do: :ok

  defp ensure_runnable(%ChatSession{status: status}) do
    if ChatSessionStatus.runnable?(status) do
      :ok
    else
      {:error, {:chat_session_not_runnable, ChatSessionStatus.wire_value(status)}}
    end
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

  defp async_inference_opts do
    Keyword.get(chat_inference_config(), :async_opts, [])
  end

  defp async_inference_enabled? do
    Keyword.get(chat_inference_config(), :async, true)
  end

  defp chat_inference_config do
    Application.get_env(:sacrum, :chat_inference, [])
  end
end
