defmodule Sacrum.ChatSessionRunner.Pipeline do
  @moduledoc """
  Durable chat-session pipeline orchestration used by the runner's Jido actions.

  This module remains the public action-facing entrypoint. Subdomain modules own
  session state, turn lookup, transcript persistence, runner events, inference
  event idempotency, and direct tracker execution details.
  """

  alias Sacrum.Accounts.AuthoringChatLoop
  alias Sacrum.Accounts.ChatEvents
  alias Sacrum.Chat.Inference
  alias Sacrum.ChatSessionRunner.DirectTracker
  alias Sacrum.ChatSessionRunner.DirectTracker.Continuation, as: DirectTrackerContinuation

  alias Sacrum.ChatSessionRunner.Events.{
    ActivityEvents,
    Checkpoints,
    InferenceEvents,
    MessageEvents
  }

  alias Sacrum.ChatSessionRunner.Session.{State, Turn}
  alias Sacrum.ChatSessionRunner.Transcript.{InferenceMessages, Messages}
  alias Sacrum.Repo.Schemas.{ChatEvent, ChatMessage, ChatSession}

  @spec fetch_session(String.t()) :: {:ok, ChatSession.t()} | {:error, term()}
  defdelegate fetch_session(chat_session_id), to: State

  @spec ensure_runnable(ChatSession.t()) ::
          {:continue, ChatSession.t()} | {:halt, ChatSession.t(), term()}
  defdelegate ensure_runnable(session), to: State

  @spec refresh_runnable_session(ChatSession.t()) ::
          {:ok, ChatSession.t()}
          | {:halt, ChatSession.t(), term()}
          | {:error, term()}
  defdelegate refresh_runnable_session(session), to: State

  @spec pending_user_turn_after?(ChatSession.t(), String.t() | nil) :: boolean()
  defdelegate pending_user_turn_after?(session, turn_message_id), to: State

  @spec surface_failure(String.t(), term()) :: :ok | {:error, term()}
  defdelegate surface_failure(chat_session_id, reason), to: State

  @spec mark_failed(String.t(), term()) :: {:error, term()}
  defdelegate mark_failed(chat_session_id, reason), to: State

  @spec lookup_assistant_message(ChatSession.t()) ::
          {:ok, ChatMessage.t()} | {:error, :not_found}
  defdelegate lookup_assistant_message(session), to: Messages

  @spec lookup_assistant_message(ChatSession.t(), String.t()) ::
          {:ok, ChatMessage.t()} | {:error, :not_found}
  defdelegate lookup_assistant_message(session, turn_message_id), to: Messages

  @spec intake(ChatSession.t(), String.t()) :: {:ok, ChatSession.t()} | {:error, term()}
  def intake(%ChatSession{} = session, engine_session_ref) when is_binary(engine_session_ref) do
    with {:ok, session} <- State.ensure_running_session(session, engine_session_ref),
         {:ok, _message} <-
           Messages.ensure_status_message(session, :intake, "Chat session started."),
         {:ok, _events} <- Checkpoints.checkpoint_step(session, :intake, %{"status" => "running"}) do
      {:ok, session}
    end
  end

  @spec load_messages(ChatSession.t()) :: {:ok, [ChatMessage.t()]} | {:error, term()}
  def load_messages(%ChatSession{} = session) do
    with {:ok, messages} <- Messages.list_for_session(session, include_private: true),
         {:ok, _events} <-
           Checkpoints.checkpoint_step(session, :load_messages, %{
             "message_count" => length(messages)
           }) do
      {:ok, messages}
    end
  end

  @spec invoke_inference(ChatSession.t(), [ChatMessage.t()], keyword()) ::
          {:ok, ChatSession.t(), Inference.Result.t()} | {:error, term()}
  def invoke_inference(%ChatSession{} = session, messages, inference_opts)
      when is_list(messages) and is_list(inference_opts) do
    provider_messages = InferenceMessages.conversation_messages_for_inference(messages)

    run_inference(
      session,
      provider_messages,
      inference_opts,
      :invoke_inference,
      Turn.turn_message_id(messages)
    )
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
    turn_message_id = turn_message_id || Turn.latest_user_message_id!(session)
    attrs = Messages.assistant_message_attrs(inference_result, turn_message_id)

    with {:ok, message} <- Messages.ensure_message(session, attrs),
         {:ok, _event} <- MessageEvents.ensure_public_message_event(session, message),
         {:ok, _event} <-
           InferenceEvents.append_inference_completed_event(session, message, inference_result),
         {:ok, _direct_events} <-
           DirectTracker.Runner.maybe_execute(
             session,
             inference_result,
             message.id,
             turn_message_id
           ),
         :ok <- maybe_apply_authoring_result(session, inference_result),
         {:ok, _events} <-
           Checkpoints.checkpoint_step(session, :append_assistant, %{
             "assistant_message_id" => message.id,
             "turn_message_id" => turn_message_id
           }) do
      {:ok, message}
    end
  end

  @spec execute_direct_tracker_operation(ChatSession.t(), Inference.Result.t(), String.t() | nil) ::
          {:ok, [ChatEvent.t()]} | {:error, term()}
  def execute_direct_tracker_operation(
        %ChatSession{} = session,
        %Inference.Result{} = inference_result,
        turn_message_id \\ nil
      ) do
    DirectTracker.Runner.execute(session, inference_result, %{
      "turn_message_id" => turn_message_id || Turn.latest_user_message_id!(session)
    })
  end

  @spec continue_after_direct_tracker_operation(
          ChatSession.t(),
          Inference.Result.t(),
          keyword(),
          String.t() | nil
        ) ::
          {:ok, ChatSession.t(), Inference.Result.t()}
          | {:error, term()}
          | {:halt, ChatSession.t(), term()}
  def continue_after_direct_tracker_operation(
        %ChatSession{} = session,
        %Inference.Result{} = inference_result,
        inference_opts,
        turn_message_id \\ nil
      )
      when is_list(inference_opts) do
    turn_message_id = turn_message_id || Turn.latest_user_message_id!(session)

    with {:ok, events} <-
           execute_direct_tracker_operation(session, inference_result, turn_message_id),
         {:ok, messages} <- Messages.list_for_session(session, include_private: true),
         {:ok, continuation_messages} <-
           DirectTrackerContinuation.messages(inference_result.internal_metadata, events) do
      provider_messages =
        InferenceMessages.conversation_messages_for_inference(messages) ++
          continuation_messages

      inference_opts = Keyword.put(inference_opts, :source_message_id, turn_message_id)

      run_inference(
        session,
        provider_messages,
        inference_opts,
        :continue_inference,
        turn_message_id
      )
    end
  end

  defp run_inference(
         %ChatSession{} = session,
         provider_messages,
         inference_opts,
         checkpoint_step,
         turn_message_id
       )
       when is_list(provider_messages) and is_list(inference_opts) and is_atom(checkpoint_step) do
    with {:ok, result} <- Inference.generate(provider_messages, inference_opts),
         {:ok, refreshed_session} <- State.refresh_runnable_session(session),
         metadata = inference_public_metadata(result, turn_message_id),
         {:ok, _activity_event} <- append_invoking_model_activity(refreshed_session, metadata),
         {:ok, _events} <-
           Checkpoints.checkpoint_step(refreshed_session, checkpoint_step, metadata) do
      {:ok, refreshed_session, result}
    end
  end

  defp inference_public_metadata(%Inference.Result{} = result, turn_message_id) do
    %{
      "provider" => Map.get(result.public_metadata, "provider"),
      "model" => Map.get(result.public_metadata, "model"),
      "turn_message_id" => turn_message_id
    }
  end

  defp append_invoking_model_activity(%ChatSession{} = session, metadata) do
    details = Map.put(metadata, "display", %{"label" => "Invoking model"})

    ChatEvents.append_to_session(
      session,
      ActivityEvents.invoking_model_attrs(session, details)
    )
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
    DirectTracker.Events.append_rejection(session, inference_result, turn_message_id)
  end

  @spec resume_assistant_message(ChatSession.t(), ChatMessage.t()) ::
          {:ok, ChatSession.t(), ChatMessage.t()} | {:error, term()}
  def resume_assistant_message(%ChatSession{} = session, %ChatMessage{} = message) do
    with {:ok, session} <- State.refresh_runnable_session(session),
         {:ok, _event} <- MessageEvents.ensure_public_message_event(session, message),
         {:ok, event} <-
           InferenceEvents.ensure_resumed_inference_completed_event(session, message),
         :ok <- apply_resumed_authoring_intent(session, event),
         {:ok, _events} <-
           Checkpoints.checkpoint_step(session, :append_assistant, %{
             "assistant_message_id" => message.id,
             "turn_message_id" => Turn.turn_message_id_from_assistant(message),
             "resumed" => true
           }) do
      {:ok, session, message}
    end
  end

  @spec complete_session(ChatSession.t(), String.t() | nil) ::
          {:ok, ChatSession.t()} | {:error, term()}
  def complete_session(%ChatSession{} = session, turn_message_id \\ nil) do
    turn_message_id = turn_message_id || Turn.latest_user_message_id!(session)

    with {:ok, session} <- State.refresh_runnable_session(session),
         {:ok, _message} <-
           Messages.ensure_status_message(
             session,
             :complete_session,
             "Chat turn completed.",
             turn_message_id
           ),
         {:ok, _activity_event} <-
           ActivityEvents.ensure_completed(session, %{
             "turn_message_id" => turn_message_id,
             "display" => %{"label" => "Completed"}
           }),
         {:ok, _events} <-
           Checkpoints.checkpoint_step(session, :complete_session, %{
             "status" => "turn_completed",
             "turn_message_id" => turn_message_id
           }) do
      {:ok, session}
    end
  end

  @spec apply_resumed_authoring_intent(ChatSession.t(), ChatEvent.t()) :: :ok | {:error, term()}
  defp apply_resumed_authoring_intent(%ChatSession{} = session, %ChatEvent{} = event) do
    metadata = get_in(event.internal_payload || %{}, ["metadata"]) || %{}

    AuthoringChatLoop.apply_inference_metadata(session, metadata)
  end

  @spec maybe_apply_authoring_result(ChatSession.t(), Inference.Result.t()) ::
          :ok | {:error, term()}
  defp maybe_apply_authoring_result(%ChatSession{} = session, %Inference.Result{} = result) do
    if DirectTracker.Operations.direct_tracker_metadata?(result) do
      :ok
    else
      AuthoringChatLoop.apply_inference_result(session, result)
    end
  end
end
