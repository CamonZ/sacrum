defmodule Sacrum.ChatSessionRunner.Session.Hydration do
  @moduledoc """
  Crash-recovery snapshot derivation for persisted chat session runner state.

  Hydration derives deterministic snapshots only from `chat_sessions`,
  `chat_messages`, and `chat_events`, so the runner can recover without relying
  on in-memory AgentServer state surviving a crash.
  """

  alias Sacrum.ChatSessionRunner.DirectTracker
  alias Sacrum.ChatSessionRunner.Events.Checkpoints
  alias Sacrum.ChatSessionRunner.Session.{State, Turn}
  alias Sacrum.ChatSessionRunner.Signals
  alias Sacrum.ChatSessionRunner.Transcript.Messages
  alias Sacrum.Repo.Schemas.{ChatMessage, ChatSession}

  @type turn_state ::
          :no_pending_turn
          | :pending_user_turn
          | :partially_completed_tool_turn
          | :completed_turn
          | :failed_turn

  defmodule Snapshot do
    @moduledoc false

    @type t :: %__MODULE__{
            chat_session_id: String.t(),
            status: atom() | nil,
            turn_state: Sacrum.ChatSessionRunner.Session.Hydration.turn_state() | nil,
            turn_message_id: String.t() | nil,
            next_signal: String.t() | nil,
            last_checkpoint: atom() | nil,
            idempotency_keys: map()
          }

    defstruct [
      :chat_session_id,
      :status,
      :turn_state,
      :turn_message_id,
      :next_signal,
      :last_checkpoint,
      idempotency_keys: %{}
    ]
  end

  @spec hydrate_session(String.t()) :: {:ok, Snapshot.t()} | {:error, term()}
  def hydrate_session(chat_session_id) when is_binary(chat_session_id) do
    with {:ok, %ChatSession{} = session} <- State.fetch_session(chat_session_id) do
      {:ok, build_snapshot(session)}
    end
  end

  @spec build_snapshot(ChatSession.t()) :: Snapshot.t()
  defp build_snapshot(%ChatSession{} = session) do
    user_message = latest_user_message(session)
    turn_message_id = message_id(user_message)
    assistant_message = assistant_for_turn(session, turn_message_id)
    durable_state = durable_state(session, turn_message_id)

    %Snapshot{
      chat_session_id: session.id,
      status: session.status,
      turn_state: turn_state(session, turn_message_id, assistant_message, durable_state),
      turn_message_id: turn_message_id,
      next_signal: next_signal(session, turn_message_id, assistant_message, durable_state),
      last_checkpoint: durable_state.last_checkpoint,
      idempotency_keys:
        idempotency_keys(
          durable_state,
          user_message,
          assistant_message,
          turn_message_id
        )
    }
  end

  defp latest_user_message(session) do
    case Turn.latest_user_message(session) do
      {:ok, message} -> message
      {:error, :not_found} -> nil
    end
  end

  defp message_id(%ChatMessage{id: id}), do: id
  defp message_id(nil), do: nil

  defp assistant_for_turn(_session, nil), do: nil

  defp assistant_for_turn(session, turn_message_id) do
    case Messages.lookup_assistant_message(session, turn_message_id) do
      {:ok, message} -> message
      {:error, :not_found} -> nil
    end
  end

  defp durable_state(_session, nil) do
    %{
      last_checkpoint: nil,
      completion_recorded?: false,
      failure_recorded?: false,
      direct_tracker_completed?: false
    }
  end

  defp durable_state(session, turn_message_id) do
    recorded_steps = Checkpoints.recorded_steps_for_turn(session, turn_message_id)

    %{
      last_checkpoint: Checkpoints.last_recorded_step(recorded_steps),
      completion_recorded?: :complete_session in recorded_steps,
      failure_recorded?: :failed in recorded_steps,
      direct_tracker_completed?: direct_tracker_completed?(session, turn_message_id)
    }
  end

  defp turn_state(
         %ChatSession{status: :failed},
         _turn_message_id,
         _assistant_message,
         _durable_state
       ),
       do: :failed_turn

  defp turn_state(_session, nil, _assistant_message, _durable_state), do: :no_pending_turn

  defp turn_state(_session, _turn_message_id, _assistant_message, %{completion_recorded?: true}),
    do: :completed_turn

  defp turn_state(_session, _turn_message_id, _assistant_message, %{failure_recorded?: true}),
    do: :failed_turn

  defp turn_state(_session, _turn_message_id, assistant_message, durable_state) do
    cond do
      not is_nil(assistant_message) and durable_state.last_checkpoint == :append_assistant ->
        :partially_completed_tool_turn

      durable_state.direct_tracker_completed? or
          (not is_nil(assistant_message) and
             durable_state.last_checkpoint in [:invoke_inference, :continue_inference]) ->
        :partially_completed_tool_turn

      true ->
        :pending_user_turn
    end
  end

  defp next_signal(
         %ChatSession{status: :failed},
         _turn_message_id,
         _assistant_message,
         _durable_state
       ),
       do: Signals.noop()

  defp next_signal(_session, nil, _assistant_message, _durable_state), do: Signals.noop()

  defp next_signal(_session, _turn_message_id, _assistant_message, %{completion_recorded?: true}),
    do: Signals.noop()

  defp next_signal(_session, _turn_message_id, _assistant_message, %{failure_recorded?: true}),
    do: Signals.noop()

  defp next_signal(_session, _turn_message_id, assistant_message, durable_state) do
    pending_signal(assistant_message, durable_state)
  end

  defp pending_signal(%ChatMessage{}, %{last_checkpoint: :append_assistant}),
    do: Signals.complete_session()

  defp pending_signal(_assistant_message, %{direct_tracker_completed?: true}),
    do: Signals.resume_assistant()

  defp pending_signal(%ChatMessage{}, %{last_checkpoint: checkpoint})
       when checkpoint in [:invoke_inference, :continue_inference],
       do: Signals.resume_assistant()

  defp pending_signal(_assistant_message, %{last_checkpoint: :intake}),
    do: Signals.load_messages()

  defp pending_signal(_assistant_message, %{last_checkpoint: :load_messages}),
    do: Signals.invoke_inference()

  defp pending_signal(_assistant_message, %{last_checkpoint: checkpoint})
       when checkpoint in [:invoke_inference, :continue_inference],
       do: Signals.invoke_inference()

  defp pending_signal(_assistant_message, _durable_state), do: Signals.intake()

  defp idempotency_keys(
         durable_state,
         user_message,
         assistant_message,
         turn_message_id
       ) do
    %{
      "user_client_message_id" => client_message_id(user_message),
      "assistant_client_message_id" =>
        assistant_client_message_id(
          assistant_message,
          turn_message_id,
          durable_state.last_checkpoint
        ),
      "durable_marker" => durable_marker(durable_state)
    }
  end

  defp client_message_id(%ChatMessage{client_message_id: client_message_id}),
    do: client_message_id

  defp client_message_id(nil), do: nil

  defp assistant_client_message_id(
         %ChatMessage{client_message_id: client_message_id},
         _turn_id,
         _checkpoint
       ),
       do: client_message_id

  defp assistant_client_message_id(nil, turn_message_id, checkpoint)
       when is_binary(turn_message_id) and checkpoint in [:invoke_inference, :continue_inference],
       do: Turn.assistant_client_message_id(turn_message_id)

  defp assistant_client_message_id(nil, _turn_message_id, _checkpoint), do: nil

  defp durable_marker(durable_state) do
    cond do
      durable_state.failure_recorded? -> :failure_recorded
      durable_state.completion_recorded? -> :completion_recorded
      durable_state.direct_tracker_completed? -> :direct_tracker_operation_completed
      true -> nil
    end
  end

  defp direct_tracker_completed?(%ChatSession{} = session, turn_message_id) do
    DirectTracker.Events.completed_for_turn?(session, turn_message_id)
  end
end
