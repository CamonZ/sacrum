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

  alias Sacrum.Accounts.{AuthoringChatLoop, ChatEvents, ChatMessages, ChatSessions}

  alias Sacrum.Chat.{
    DirectTrackerOperationExecutor,
    DirectTrackerOperationResolver,
    Inference,
    InferenceEvents,
    PublicEvents
  }

  alias Sacrum.ChatSessions.Status, as: ChatSessionStatus
  alias Sacrum.Repo
  alias Sacrum.Repo.ChatSessions, as: ChatSessionsRepo
  alias Sacrum.Repo.Schemas.{ChatEvent, ChatMessage, ChatSession}

  import Ecto.Query

  @engine_kind "jido"
  @runner_version 1
  @assistant_client_message_id_prefix "chat_session_runner:assistant:v1"

  @public_payload_keys ~w(status message_count assistant_message_id resumed provider model turn_message_id)

  @spec fetch_session(String.t()) :: {:ok, ChatSession.t()} | {:error, term()}
  def fetch_session(chat_session_id) when is_binary(chat_session_id) do
    ChatSessionsRepo.get(chat_session_id)
  end

  @spec ensure_runnable(ChatSession.t()) ::
          {:continue, ChatSession.t()} | {:halt, ChatSession.t(), term()}
  def ensure_runnable(%ChatSession{} = session) do
    cond do
      session.status in [:cancelled, :cancelling] ->
        {:halt, session, {:terminal_status, session.status}}

      session.status in [:completed, :failed] ->
        if pending_user_turn?(session) do
          {:continue, session}
        else
          {:halt, session, {:terminal_status, session.status}}
        end

      ChatSessionStatus.terminal?(session.status) ->
        {:halt, session, {:terminal_status, session.status}}

      true ->
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
    with {:ok, messages} <- ChatMessages.list_for_session(session, include_private: true),
         {:ok, _events} <-
           checkpoint_step(session, :load_messages, %{"message_count" => length(messages)}) do
      {:ok, messages}
    end
  end

  @spec lookup_assistant_message(ChatSession.t()) ::
          {:ok, ChatMessage.t()} | {:error, :not_found}
  def lookup_assistant_message(%ChatSession{} = session) do
    with {:ok, turn_message} <- latest_user_message(session) do
      lookup_assistant_message(session, turn_message.id)
    end
  end

  @spec lookup_assistant_message(ChatSession.t(), String.t()) ::
          {:ok, ChatMessage.t()} | {:error, :not_found}
  def lookup_assistant_message(%ChatSession{} = session, turn_message_id)
      when is_binary(turn_message_id) do
    ChatMessages.get_by_client_message_id(session, assistant_client_message_id(turn_message_id))
  end

  @spec invoke_inference(ChatSession.t(), [ChatMessage.t()], keyword()) ::
          {:ok, ChatSession.t(), Inference.Result.t()} | {:error, term()}
  def invoke_inference(%ChatSession{} = session, messages, inference_opts)
      when is_list(messages) and is_list(inference_opts) do
    with {:ok, result} <-
           Inference.generate(conversation_messages_for_inference(messages), inference_opts),
         {:ok, session} <- refresh_runnable_session(session),
         {:ok, _events} <-
           checkpoint_step(session, :invoke_inference, %{
             "provider" => Map.get(result.public_metadata, "provider"),
             "model" => Map.get(result.public_metadata, "model"),
             "turn_message_id" => turn_message_id(messages)
           }) do
      {:ok, session, result}
    end
  end

  @spec append_assistant_message(ChatSession.t(), Inference.Result.t()) ::
          {:ok, ChatMessage.t()} | {:error, term()}
  @spec append_assistant_message(ChatSession.t(), Inference.Result.t(), String.t() | nil) ::
          {:ok, ChatMessage.t()} | {:error, term()}
  def append_assistant_message(
        %ChatSession{} = session,
        %Inference.Result{} = inference_result,
        turn_message_id \\ nil
      ) do
    turn_message_id = turn_message_id || latest_user_message_id!(session)

    attrs =
      InferenceEvents.assistant_message_attrs(inference_result,
        client_message_id: assistant_client_message_id(turn_message_id)
      )

    with {:ok, message} <- ensure_message(session, attrs),
         {:ok, _event} <- ensure_public_message_event(session, message),
         {:ok, _event} <- append_inference_completed_event(session, message, inference_result),
         {:ok, _direct_event_or_nil} <-
           maybe_execute_direct_tracker_operation(
             session,
             inference_result,
             message,
             turn_message_id
           ),
         :ok <- maybe_apply_authoring_result(session, inference_result),
         {:ok, _events} <-
           checkpoint_step(session, :append_assistant, %{
             "assistant_message_id" => message.id,
             "turn_message_id" => turn_message_id
           }) do
      {:ok, message}
    end
  end

  @spec execute_direct_tracker_operation(ChatSession.t(), Inference.Result.t(), String.t() | nil) ::
          {:ok, ChatEvent.t()} | {:error, term()}
  def execute_direct_tracker_operation(
        %ChatSession{} = session,
        %Inference.Result{} = inference_result,
        turn_message_id \\ nil
      ) do
    execute_and_record_direct_tracker_operation(session, inference_result, %{
      "turn_message_id" => turn_message_id || latest_user_message_id!(session)
    })
  end

  @spec record_direct_tracker_operation_rejection(
          ChatSession.t(),
          Inference.Result.t(),
          String.t() | nil
        ) :: {:ok, ChatEvent.t()} | {:error, term()}
  def record_direct_tracker_operation_rejection(
        %ChatSession{} = session,
        %Inference.Result{} = inference_result,
        turn_message_id \\ nil
      ) do
    rejection =
      Map.fetch!(inference_result.internal_metadata, "direct_tracker_operation_rejected")

    reason = public_direct_tracker_rejection_reason(rejection)

    ChatEvents.append_to_session(session, %{
      event_type: "chat_direct_tracker_operation.rejected",
      visibility: :public,
      public_payload: %{
        "status" => "rejected",
        "reason" => reason,
        "turn_message_id" => turn_message_id || latest_user_message_id!(session)
      },
      internal_payload: Inference.scrub_secrets(%{"rejection" => rejection})
    })
  end

  @spec resume_assistant_message(ChatSession.t(), ChatMessage.t()) ::
          {:ok, ChatSession.t(), ChatMessage.t()} | {:error, term()}
  def resume_assistant_message(%ChatSession{} = session, %ChatMessage{} = message) do
    with {:ok, session} <- refresh_runnable_session(session),
         {:ok, _event} <- ensure_public_message_event(session, message),
         {:ok, event} <- ensure_resumed_inference_completed_event(session, message),
         :ok <- apply_resumed_authoring_intent(session, event),
         {:ok, _events} <-
           checkpoint_step(session, :append_assistant, %{
             "assistant_message_id" => message.id,
             "turn_message_id" => turn_message_id_from_assistant(message),
             "resumed" => true
           }) do
      {:ok, session, message}
    end
  end

  @spec complete_session(ChatSession.t(), String.t() | nil) ::
          {:ok, ChatSession.t()} | {:error, term()}
  def complete_session(%ChatSession{} = session, turn_message_id \\ nil) do
    turn_message_id = turn_message_id || latest_user_message_id!(session)

    with {:ok, session} <- refresh_runnable_session(session),
         {:ok, _message} <-
           ensure_status_message(
             session,
             :complete_session,
             "Chat session completed.",
             turn_message_id
           ),
         {:ok, session} <- ensure_completed_session(session),
         {:ok, _events} <-
           checkpoint_step(session, :complete_session, %{
             "status" => "completed",
             "turn_message_id" => turn_message_id
           }) do
      {:ok, session}
    end
  end

  @spec pending_user_turn_after?(ChatSession.t(), String.t() | nil) :: boolean()
  def pending_user_turn_after?(%ChatSession{}, nil), do: false

  def pending_user_turn_after?(%ChatSession{} = session, turn_message_id)
      when is_binary(turn_message_id) do
    with {:ok, turn_message} <- get_message(session, turn_message_id),
         {:ok, latest_user} <- latest_user_message(session) do
      latest_user.id != turn_message.id and compare_messages(latest_user, turn_message) == :gt and
        match?({:error, :not_found}, lookup_assistant_message(session, latest_user.id))
    else
      {:error, :not_found} -> false
    end
  end

  @spec surface_failure(String.t(), term()) :: :ok | {:error, term()}
  def surface_failure(chat_session_id, reason) when is_binary(chat_session_id) do
    case ChatSessionsRepo.get(chat_session_id) do
      {:ok, %ChatSession{} = session} ->
        failed_reason = inspect(reason)

        with {:continue, session} <- ensure_runnable(session),
             {:ok, failed_session} <- update_session_with_event(session, %{status: :failed}),
             {:ok, _events} <-
               checkpoint_step(failed_session, :failed, %{"reason" => failed_reason}) do
          :ok
        else
          {:halt, _session, _reason} -> :ok
          {:error, failure_reason} -> {:error, failure_reason}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @spec mark_failed(String.t(), term()) :: {:error, term()}
  def mark_failed(chat_session_id, reason) when is_binary(chat_session_id) do
    case surface_failure(chat_session_id, reason) do
      :ok -> {:error, reason}
      {:error, _failure_reason} -> {:error, reason}
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
      ended_at: nil,
      stop_requested_at: nil,
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
      {:ok, {updated_session, _event}} ->
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
  @spec ensure_status_message(ChatSession.t(), atom(), String.t(), String.t() | nil) ::
          {:ok, ChatMessage.t()} | {:error, term()}
  defp ensure_status_message(
         %ChatSession{} = session,
         step,
         content,
         turn_message_id \\ nil
       )
       when is_atom(step) do
    turn_message_id = turn_message_id || latest_user_message_id!(session)

    attrs = %{
      role: :status,
      content: content,
      content_format: :plain,
      client_message_id: "chat_session_runner:status:#{step}:v1:#{turn_message_id}",
      metadata: %{
        "runner" => "chat_session_runner",
        "runner_version" => @runner_version,
        "step" => Atom.to_string(step),
        "turn_message_id" => turn_message_id,
        "visibility" => "internal"
      }
    }

    ensure_message(session, attrs)
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
        ChatEvents.append_to_session(session, PublicEvents.message_created_attrs(message))
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
    assistant_message_id = attrs.internal_payload["assistant_message_id"]

    case get_inference_completed_for_assistant(session, assistant_message_id) do
      {:ok, event} -> {:ok, event}
      {:error, :not_found} -> ChatEvents.append_to_session(session, attrs)
    end
  end

  defp apply_resumed_authoring_intent(%ChatSession{} = session, %ChatEvent{} = event) do
    metadata = get_in(event.internal_payload || %{}, ["metadata"]) || %{}

    AuthoringChatLoop.apply_inference_metadata(session, metadata)
  end

  defp maybe_execute_direct_tracker_operation(
         %ChatSession{} = session,
         %Inference.Result{} = inference_result,
         %ChatMessage{} = message,
         turn_message_id
       ) do
    case direct_tracker_operation(inference_result) do
      {:error, :not_found} ->
        {:ok, nil}

      {:ok, operation} ->
        execute_and_record_direct_tracker_operation(session, operation, %{
          "assistant_message_id" => message.id,
          "turn_message_id" => turn_message_id
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute_and_record_direct_tracker_operation(
         %ChatSession{} = session,
         %Inference.Result{} = inference_result,
         extra_public_payload
       ) do
    with {:ok, operation} <- direct_tracker_operation(inference_result) do
      execute_and_record_direct_tracker_operation(session, operation, extra_public_payload)
    end
  end

  defp execute_and_record_direct_tracker_operation(
         %ChatSession{} = session,
         operation,
         extra_public_payload
       ) do
    with {:ok, result} <- DirectTrackerOperationExecutor.execute(operation) do
      append_direct_tracker_operation_completed_event(
        session,
        operation,
        result,
        extra_public_payload
      )
    end
  end

  defp maybe_apply_authoring_result(%ChatSession{} = session, %Inference.Result{} = result) do
    if direct_tracker_metadata?(result) do
      :ok
    else
      AuthoringChatLoop.apply_inference_result(session, result)
    end
  end

  defp direct_tracker_metadata?(%Inference.Result{} = result) do
    metadata = direct_tracker_metadata(result)

    is_map(Map.get(metadata, "resolved_direct_tracker_operation")) or
      is_map(Map.get(metadata, "direct_tracker_operation_rejected"))
  end

  defp direct_tracker_operation(%Inference.Result{} = result) do
    case Map.get(direct_tracker_metadata(result), "resolved_direct_tracker_operation") do
      nil ->
        {:error, :not_found}

      %{} = serialized ->
        DirectTrackerOperationResolver.deserialize_resolution(serialized)

      _other ->
        {:error, :invalid_direct_tracker_operation}
    end
  end

  defp direct_tracker_metadata(%Inference.Result{internal_metadata: metadata})
       when is_map(metadata),
       do: metadata

  defp direct_tracker_metadata(%Inference.Result{}), do: %{}

  defp append_direct_tracker_operation_completed_event(
         %ChatSession{} = session,
         operation,
         result,
         extra_public_payload
       ) do
    ChatEvents.append_to_session(session, %{
      event_type: "chat_direct_tracker_operation.completed",
      visibility: :public,
      public_payload:
        %{
          "action" => operation.action,
          "status" => "succeeded",
          "target" => public_direct_tracker_target(operation),
          "result" => public_direct_tracker_result(result)
        }
        |> Map.merge(extra_public_payload)
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new(),
      internal_payload:
        Inference.scrub_secrets(%{
          "operation" => DirectTrackerOperationResolver.serialize_resolution(operation),
          "result" => stringify_direct_tracker_result(result)
        })
    })
  end

  defp public_direct_tracker_result(%{section: section}),
    do: stringify_direct_tracker_result(section)

  defp public_direct_tracker_result(%{workflow_step: step}),
    do: stringify_direct_tracker_result(step)

  defp public_direct_tracker_result(%{task: task}), do: stringify_direct_tracker_result(task)
  defp public_direct_tracker_result(result), do: stringify_direct_tracker_result(result)

  defp public_direct_tracker_target(operation) do
    operation
    |> DirectTrackerOperationResolver.serialize_resolution()
    |> DirectTrackerOperationResolver.public_target()
  end

  defp stringify_direct_tracker_result(result) when is_map(result) do
    Map.new(result, fn {key, value} -> {to_string(key), stringify_direct_tracker_value(value)} end)
  end

  defp stringify_direct_tracker_value(value) when is_map(value),
    do: stringify_direct_tracker_result(value)

  defp stringify_direct_tracker_value(value) when is_list(value),
    do: Enum.map(value, &stringify_direct_tracker_value/1)

  defp stringify_direct_tracker_value(value), do: value

  defp public_direct_tracker_rejection_reason(%{"reason_code" => reason})
       when reason in ["ambiguous_target", "out_of_scope"],
       do: reason

  defp public_direct_tracker_rejection_reason(_rejection), do: "out_of_scope"

  @spec checkpoint_step(ChatSession.t(), atom(), map()) ::
          {:ok, [ChatEvent.t()]} | {:error, term()}
  defp checkpoint_step(%ChatSession{} = session, step, details)
       when is_atom(step) and is_map(details) do
    event_type = "chat_session_runner.#{step}.completed"
    details = Map.put_new(details, "turn_message_id", latest_user_message_id!(session))
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
    case get_checkpoint_event(session, event_type, visibility, public_payload, internal_payload) do
      {:ok, event} ->
        {:ok, event}

      {:error, :not_found} ->
        attrs = %{
          event_type: event_type,
          visibility: visibility,
          public_payload: public_payload,
          internal_payload: internal_payload
        }

        ChatEvents.append_to_session(session, attrs)
    end
  end

  @spec pending_user_turn?(ChatSession.t()) :: boolean()
  defp pending_user_turn?(%ChatSession{} = session) do
    case latest_user_message(session) do
      {:ok, user_message} ->
        case lookup_assistant_message(session, user_message.id) do
          {:ok, _assistant_message} -> false
          {:error, :not_found} -> true
        end

      {:error, :not_found} ->
        false
    end
  end

  @spec latest_user_message(ChatSession.t()) :: {:ok, ChatMessage.t()} | {:error, :not_found}
  defp latest_user_message(%ChatSession{} = session) do
    latest_message_by_role(session, :user)
  end

  @spec latest_message_by_role(ChatSession.t(), atom()) ::
          {:ok, ChatMessage.t()} | {:error, :not_found}
  defp latest_message_by_role(%ChatSession{} = session, role) do
    query =
      from message in ChatMessage,
        where:
          message.user_id == ^session.user_id and message.project_id == ^session.project_id and
            message.chat_session_id == ^session.id and message.role == ^role,
        order_by: [desc: message.inserted_at, desc: message.id],
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      message -> {:ok, message}
    end
  end

  @spec get_message(ChatSession.t(), String.t()) :: {:ok, ChatMessage.t()} | {:error, :not_found}
  defp get_message(%ChatSession{} = session, message_id) do
    query =
      from message in ChatMessage,
        where:
          message.user_id == ^session.user_id and message.project_id == ^session.project_id and
            message.chat_session_id == ^session.id and message.id == ^message_id,
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      message -> {:ok, message}
    end
  end

  @spec latest_user_message_id!(ChatSession.t()) :: String.t()
  defp latest_user_message_id!(%ChatSession{} = session) do
    case latest_user_message(session) do
      {:ok, message} -> message.id
      {:error, :not_found} -> raise ArgumentError, "chat session has no user message"
    end
  end

  @spec turn_message_id([ChatMessage.t()]) :: String.t() | nil
  defp turn_message_id(messages) when is_list(messages) do
    messages
    |> Enum.filter(&(&1.role == :user))
    |> List.last()
    |> case do
      %ChatMessage{id: id} -> id
      nil -> nil
    end
  end

  @spec conversation_messages_for_inference([ChatMessage.t()]) :: [ChatMessage.t()]
  defp conversation_messages_for_inference(messages) do
    assistant_by_turn =
      messages
      |> Enum.filter(&(&1.role == :assistant))
      |> Map.new(fn message -> {turn_message_id_from_assistant(message), message} end)
      |> Map.delete(nil)

    messages
    |> Enum.filter(&(&1.role == :user))
    |> Enum.flat_map(fn user_message ->
      case Map.fetch(assistant_by_turn, user_message.id) do
        {:ok, assistant_message} -> [user_message, assistant_message]
        :error -> [user_message]
      end
    end)
  end

  @spec assistant_client_message_id(String.t()) :: String.t()
  defp assistant_client_message_id(turn_message_id) when is_binary(turn_message_id) do
    "#{@assistant_client_message_id_prefix}:#{turn_message_id}"
  end

  @spec turn_message_id_from_assistant(ChatMessage.t()) :: String.t() | nil
  defp turn_message_id_from_assistant(%ChatMessage{client_message_id: client_message_id})
       when is_binary(client_message_id) do
    prefix = "#{@assistant_client_message_id_prefix}:"

    if String.starts_with?(client_message_id, prefix) do
      String.replace_prefix(client_message_id, prefix, "")
    end
  end

  defp turn_message_id_from_assistant(_message), do: nil

  @spec compare_messages(ChatMessage.t(), ChatMessage.t()) :: :lt | :eq | :gt
  defp compare_messages(%ChatMessage{} = left, %ChatMessage{} = right) do
    case DateTime.compare(left.inserted_at, right.inserted_at) do
      :eq -> compare_ids(left.id, right.id)
      comparison -> comparison
    end
  end

  defp compare_ids(left_id, right_id) do
    cond do
      left_id > right_id -> :gt
      left_id < right_id -> :lt
      true -> :eq
    end
  end

  defp get_checkpoint_event(session, event_type, visibility, public_payload, internal_payload) do
    turn_message_id =
      public_payload["turn_message_id"] ||
        get_in(internal_payload, ["details", "turn_message_id"])

    if turn_message_id do
      get_checkpoint_event_for_turn(session, event_type, visibility, turn_message_id)
    else
      ChatEvents.get_by_type(session, event_type, visibility)
    end
  end

  defp get_checkpoint_event_for_turn(session, event_type, visibility, turn_message_id) do
    query =
      from event in ChatEvent,
        where:
          event.user_id == ^session.user_id and event.project_id == ^session.project_id and
            event.chat_session_id == ^session.id and event.event_type == ^event_type and
            event.visibility == ^visibility and
            (fragment("?->>'turn_message_id' = ?", event.public_payload, ^turn_message_id) or
               fragment(
                 "?->'details'->>'turn_message_id' = ?",
                 event.internal_payload,
                 ^turn_message_id
               )),
        order_by: [asc: event.inserted_at, asc: event.id],
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      event -> {:ok, event}
    end
  end

  defp get_inference_completed_for_assistant(session, assistant_message_id)
       when is_binary(assistant_message_id) do
    query =
      from event in ChatEvent,
        where:
          event.user_id == ^session.user_id and event.project_id == ^session.project_id and
            event.chat_session_id == ^session.id and
            event.event_type == ^InferenceEvents.event_type(:inference_completed) and
            event.visibility == :internal and
            fragment(
              "?->>'assistant_message_id' = ?",
              event.internal_payload,
              ^assistant_message_id
            ),
        order_by: [asc: event.inserted_at, asc: event.id],
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      event -> {:ok, event}
    end
  end

  defp get_inference_completed_for_assistant(_session, _assistant_message_id),
    do: {:error, :not_found}
end
