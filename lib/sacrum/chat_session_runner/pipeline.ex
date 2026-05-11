defmodule Sacrum.ChatSessionRunner.Pipeline do
  @moduledoc """
  Durable chat-session pipeline operations used by the runner's Jido actions.

  Each function corresponds to one step in the session-first run loop and only
  touches Sacrum-owned persistence (`ChatSession`, `ChatMessage`, `ChatEvent`).
  The Jido AgentServer is the runtime coordination boundary; this module keeps
  Sacrum as the source of truth.

  Functions are deliberately small and idempotent so that re-running a step
  after a partial result does not duplicate messages, public events, or
  internal inference completion records.
  """

  alias Sacrum.Accounts.{ChatEvents, ChatMessages, ChatSessions}
  alias Sacrum.Chat.{Inference, InferenceEvents, PublicEvents}
  alias Sacrum.ChatSessions.Status, as: ChatSessionStatus
  alias Sacrum.Repo
  alias Sacrum.Repo.Broadcaster
  alias Sacrum.Repo.ChatSessions, as: ChatSessionsRepo
  alias Sacrum.Repo.Schemas.{ChatEvent, ChatMessage, ChatSession}

  @engine_kind "jido"
  @runner_version 1
  @assistant_client_message_id "chat_session_runner:assistant:v1"

  @public_payload_keys ~w(status message_count assistant_message_id resumed provider model)

  @spec fetch_session(String.t()) :: {:ok, ChatSession.t()} | {:error, term()}
  def fetch_session(chat_session_id) when is_binary(chat_session_id) do
    ChatSessionsRepo.get(chat_session_id)
  end

  @spec ensure_runnable(ChatSession.t()) ::
          {:continue, ChatSession.t()} | {:halt, ChatSession.t(), term()}
  def ensure_runnable(%ChatSession{} = session) do
    if ChatSessionStatus.terminal?(session.status) do
      {:halt, session, {:terminal_status, session.status}}
    else
      {:continue, session}
    end
  end

  @spec refresh_runnable_session(ChatSession.t()) ::
          {:ok, ChatSession.t()}
          | {:halt, ChatSession.t(), term()}
          | {:error, term()}
  def refresh_runnable_session(%ChatSession{} = session) do
    with {:ok, refreshed_session} <- ChatSessionsRepo.get(session.id),
         {:continue, refreshed_session} <- ensure_runnable(refreshed_session) do
      {:ok, refreshed_session}
    end
  end

  @spec intake(ChatSession.t(), String.t()) :: {:ok, ChatSession.t()} | {:error, term()}
  def intake(%ChatSession{} = session, engine_session_ref) when is_binary(engine_session_ref) do
    with {:ok, session} <- ensure_running_session(session, engine_session_ref),
         {:ok, _message} <- ensure_status_message(session, :intake, "Chat session started."),
         {:ok, _events} <- checkpoint_step(session, :intake, %{"status" => "running"}) do
      {:ok, session}
    end
  end

  @spec load_messages(ChatSession.t()) :: {:ok, [ChatMessage.t()]} | {:error, term()}
  def load_messages(%ChatSession{} = session) do
    with {:ok, messages} <- ChatMessages.list_for_session(session, []),
         {:ok, _events} <-
           checkpoint_step(session, :load_messages, %{"message_count" => length(messages)}) do
      {:ok, messages}
    end
  end

  @spec lookup_assistant_message(ChatSession.t()) ::
          {:ok, ChatMessage.t()} | {:error, :not_found}
  def lookup_assistant_message(%ChatSession{} = session) do
    ChatMessages.get_by_client_message_id(session, @assistant_client_message_id)
  end

  @spec invoke_inference(ChatSession.t(), [ChatMessage.t()], keyword()) ::
          {:ok, ChatSession.t(), Inference.Result.t()} | {:error, term()}
  def invoke_inference(%ChatSession{} = session, messages, inference_opts)
      when is_list(messages) and is_list(inference_opts) do
    with {:ok, result} <- Inference.generate(messages, inference_opts),
         {:ok, session} <- refresh_runnable_session(session),
         {:ok, _events} <-
           checkpoint_step(session, :invoke_inference, %{
             "provider" => Map.get(result.public_metadata, "provider"),
             "model" => Map.get(result.public_metadata, "model")
           }) do
      {:ok, session, result}
    end
  end

  @spec append_assistant_message(ChatSession.t(), Inference.Result.t()) ::
          {:ok, ChatMessage.t()} | {:error, term()}
  def append_assistant_message(%ChatSession{} = session, %Inference.Result{} = inference_result) do
    attrs =
      InferenceEvents.assistant_message_attrs(inference_result,
        client_message_id: @assistant_client_message_id
      )

    with {:ok, message} <- ensure_message(session, attrs),
         {:ok, _event} <- ensure_public_message_event(session, message),
         {:ok, _event} <- append_inference_completed_event(session, message, inference_result),
         {:ok, _events} <-
           checkpoint_step(session, :append_assistant, %{
             "assistant_message_id" => message.id
           }) do
      {:ok, message}
    end
  end

  @spec resume_assistant_message(ChatSession.t(), ChatMessage.t()) ::
          {:ok, ChatSession.t(), ChatMessage.t()} | {:error, term()}
  def resume_assistant_message(%ChatSession{} = session, %ChatMessage{} = message) do
    with {:ok, session} <- refresh_runnable_session(session),
         {:ok, _event} <- ensure_public_message_event(session, message),
         {:ok, _event} <- ensure_resumed_inference_completed_event(session, message),
         {:ok, _events} <-
           checkpoint_step(session, :append_assistant, %{
             "assistant_message_id" => message.id,
             "resumed" => true
           }) do
      {:ok, session, message}
    end
  end

  @spec complete_session(ChatSession.t()) :: {:ok, ChatSession.t()} | {:error, term()}
  def complete_session(%ChatSession{} = session) do
    with {:ok, session} <- refresh_runnable_session(session),
         {:ok, _message} <-
           ensure_status_message(session, :complete_session, "Chat session completed."),
         {:ok, session} <- ensure_completed_session(session),
         {:ok, _events} <-
           checkpoint_step(session, :complete_session, %{"status" => "completed"}) do
      {:ok, session}
    end
  end

  @spec mark_failed(String.t(), term()) :: {:error, term()}
  def mark_failed(chat_session_id, reason) when is_binary(chat_session_id) do
    case ChatSessionsRepo.get(chat_session_id) do
      {:ok, %ChatSession{} = session} ->
        failed_reason = inspect(reason)

        with {:continue, session} <- ensure_runnable(session),
             {:ok, failed_session} <- update_session_with_event(session, %{status: :failed}),
             {:ok, _events} <-
               checkpoint_step(failed_session, :failed, %{"reason" => failed_reason}) do
          {:error, reason}
        else
          {:halt, _session, _reason} -> {:error, reason}
          {:error, _failure_reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        {:error, reason}
    end
  end

  @spec ensure_running_session(ChatSession.t(), String.t()) ::
          {:ok, ChatSession.t()} | {:error, term()}
  defp ensure_running_session(
         %ChatSession{
           status: :running,
           engine_kind: @engine_kind,
           engine_session_ref: engine_session_ref
         } = session,
         engine_session_ref
       ) do
    {:ok, session}
  end

  defp ensure_running_session(%ChatSession{status: :running} = session, engine_session_ref) do
    update_session_with_event(session, %{
      engine_kind: @engine_kind,
      engine_session_ref: engine_session_ref
    })
  end

  defp ensure_running_session(%ChatSession{} = session, engine_session_ref) do
    update_session_with_event(session, %{
      status: :running,
      engine_kind: @engine_kind,
      engine_session_ref: engine_session_ref
    })
  end

  @spec ensure_completed_session(ChatSession.t()) ::
          {:ok, ChatSession.t()} | {:error, term()}
  defp ensure_completed_session(%ChatSession{status: :completed} = session), do: {:ok, session}

  defp ensure_completed_session(%ChatSession{} = session) do
    update_session_with_event(session, %{status: :completed})
  end

  @spec update_session_with_event(ChatSession.t(), map()) ::
          {:ok, ChatSession.t()} | {:error, term()}
  defp update_session_with_event(%ChatSession{} = session, attrs) do
    case Repo.transaction(fn -> update_session_and_event!(session, attrs) end) do
      {:ok, {updated_session, event}} ->
        Broadcaster.broadcast_chat_event({:ok, event})
        {:ok, updated_session}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec update_session_and_event!(ChatSession.t(), map()) :: {ChatSession.t(), ChatEvent.t()}
  defp update_session_and_event!(%ChatSession{} = session, attrs) do
    with {:ok, updated_session} <- ChatSessions.update_session(session, attrs),
         {:ok, event} <-
           ChatEvents.append_to_session(
             updated_session,
             PublicEvents.session_updated_attrs(updated_session)
           ) do
      {updated_session, event}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  @spec ensure_status_message(ChatSession.t(), atom(), String.t()) ::
          {:ok, ChatMessage.t()} | {:error, term()}
  defp ensure_status_message(%ChatSession{} = session, step, content) when is_atom(step) do
    attrs = %{
      role: :status,
      content: content,
      content_format: :plain,
      client_message_id: "chat_session_runner:status:#{step}:v1",
      metadata: %{
        "runner" => "chat_session_runner",
        "runner_version" => @runner_version,
        "step" => Atom.to_string(step)
      }
    }

    with {:ok, message} <- ensure_message(session, attrs),
         {:ok, _event} <- ensure_public_message_event(session, message) do
      {:ok, message}
    end
  end

  @spec ensure_message(ChatSession.t(), map()) ::
          {:ok, ChatMessage.t()} | {:error, term()}
  defp ensure_message(%ChatSession{} = session, %{client_message_id: client_message_id} = attrs) do
    case ChatMessages.get_by_client_message_id(session, client_message_id) do
      {:ok, message} -> {:ok, message}
      {:error, :not_found} -> insert_idempotent_message(session, attrs, client_message_id)
    end
  end

  @spec insert_idempotent_message(ChatSession.t(), map(), String.t()) ::
          {:ok, ChatMessage.t()} | {:error, Ecto.Changeset.t() | :not_found}
  defp insert_idempotent_message(%ChatSession{} = session, attrs, client_message_id) do
    case ChatMessages.append_to_session(session, attrs) do
      {:ok, message} ->
        {:ok, message}

      {:error, %Ecto.Changeset{} = changeset} = error ->
        if unique_client_message_conflict?(changeset) do
          ChatMessages.get_by_client_message_id(session, client_message_id)
        else
          error
        end
    end
  end

  @spec unique_client_message_conflict?(Ecto.Changeset.t()) :: boolean()
  defp unique_client_message_conflict?(%Ecto.Changeset{} = changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_message, opts}} ->
        opts[:constraint] == :unique and
          opts[:constraint_name] == "chat_messages_chat_session_id_client_message_id_index"

      _error ->
        false
    end)
  end

  @spec ensure_public_message_event(ChatSession.t(), ChatMessage.t()) ::
          {:ok, ChatEvent.t()} | {:error, term()}
  defp ensure_public_message_event(%ChatSession{} = session, %ChatMessage{} = message) do
    case ChatEvents.get_message_created_for_message(session, message.id) do
      {:ok, event} ->
        {:ok, event}

      {:error, :not_found} ->
        session
        |> ChatEvents.append_to_session(PublicEvents.message_created_attrs(message))
        |> broadcast_event_result()
    end
  end

  @spec append_inference_completed_event(ChatSession.t(), ChatMessage.t(), Inference.Result.t()) ::
          {:ok, ChatEvent.t()} | {:error, term()}
  defp append_inference_completed_event(
         %ChatSession{} = session,
         %ChatMessage{} = message,
         %Inference.Result{} = inference_result
       ) do
    attrs = InferenceEvents.inference_completed_attrs(message, inference_result)
    ensure_inference_completed_event(session, attrs)
  end

  @spec ensure_resumed_inference_completed_event(ChatSession.t(), ChatMessage.t()) ::
          {:ok, ChatEvent.t()} | {:error, term()}
  defp ensure_resumed_inference_completed_event(
         %ChatSession{} = session,
         %ChatMessage{} = message
       ) do
    attrs = InferenceEvents.resumed_inference_completed_attrs(message)
    ensure_inference_completed_event(session, attrs)
  end

  @spec ensure_inference_completed_event(ChatSession.t(), map()) ::
          {:ok, ChatEvent.t()} | {:error, term()}
  defp ensure_inference_completed_event(%ChatSession{} = session, attrs) do
    case ChatEvents.get_by_type(
           session,
           InferenceEvents.event_type(:inference_completed),
           :internal
         ) do
      {:ok, event} -> {:ok, event}
      {:error, :not_found} -> ChatEvents.append_to_session(session, attrs)
    end
  end

  @spec checkpoint_step(ChatSession.t(), atom(), map()) ::
          {:ok, [ChatEvent.t()]} | {:error, term()}
  defp checkpoint_step(%ChatSession{} = session, step, details)
       when is_atom(step) and is_map(details) do
    event_type = "chat_session_runner.#{step}.completed"
    public_payload = runner_public_payload(session, step, details)

    internal_payload =
      Inference.scrub_secrets(%{
        "runner" => "chat_session_runner",
        "runner_version" => @runner_version,
        "step" => Atom.to_string(step),
        "details" => details
      })

    with {:ok, public_event} <-
           ensure_event(session, event_type, :public, public_payload, %{}),
         {:ok, internal_event} <-
           ensure_event(session, event_type, :internal, %{}, internal_payload) do
      {:ok, [public_event, internal_event]}
    end
  end

  @spec runner_public_payload(ChatSession.t(), atom(), map()) :: map()
  defp runner_public_payload(%ChatSession{} = session, step, details) do
    details
    |> Map.take(@public_payload_keys)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Map.merge(%{
      "chat_session_id" => session.id,
      "step" => Atom.to_string(step)
    })
  end

  @spec ensure_event(ChatSession.t(), String.t(), :public | :internal, map(), map()) ::
          {:ok, ChatEvent.t()} | {:error, term()}
  defp ensure_event(
         %ChatSession{} = session,
         event_type,
         visibility,
         public_payload,
         internal_payload
       ) do
    case ChatEvents.get_by_type(session, event_type, visibility) do
      {:ok, event} ->
        {:ok, event}

      {:error, :not_found} ->
        attrs = %{
          event_type: event_type,
          visibility: visibility,
          public_payload: public_payload,
          internal_payload: internal_payload
        }

        session
        |> ChatEvents.append_to_session(attrs)
        |> broadcast_event_result()
    end
  end

  @spec broadcast_event_result({:ok, ChatEvent.t()} | {:error, term()}) ::
          {:ok, ChatEvent.t()} | {:error, term()}
  defp broadcast_event_result({:ok, event} = result) do
    Broadcaster.broadcast_chat_event(result)
    {:ok, event}
  end

  defp broadcast_event_result(error), do: error
end
