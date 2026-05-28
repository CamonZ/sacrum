defmodule Sacrum.ChatSessionRunner.Actions.HydrateSession do
  @moduledoc """
  Rehydrates the AgentServer runtime state from persisted chat runner records.
  """

  use Jido.Action,
    name: "sacrum_chat_session_hydrate_session",
    description: "Derive chat session runner state from persisted transcript and events",
    category: "chat",
    tags: ["sacrum", "chat", "session", "hydrate"],
    vsn: "1.0.0",
    schema: [
      chat_session_id: [type: :string, required: true],
      engine_session_ref: [type: :string, required: true],
      inference_opts: [type: :any, default: []],
      queued_user_turn_signal: [type: :any]
    ]

  alias Sacrum.ChatSessionRunner.Actions
  alias Sacrum.ChatSessionRunner.Session.Hydration
  alias Sacrum.ChatSessionRunner.Signals

  @impl true
  def run(params, _context) do
    with {:ok, snapshot} <- Hydration.hydrate_session(params.chat_session_id) do
      result = %{
        status: agent_status(snapshot),
        activity: snapshot.turn_state,
        step: :hydrate_session,
        chat_session_id: snapshot.chat_session_id,
        engine_session_ref: params.engine_session_ref,
        inference_opts: params.inference_opts,
        queued_user_turn_signal: queued_user_turn_signal(params, snapshot),
        hydration: snapshot
      }

      maybe_emit_next(result, snapshot, params)
    end
  end

  defp maybe_emit_next(result, snapshot, params) do
    if snapshot.next_signal in [nil, Signals.noop()] do
      maybe_emit_queued_user_turn(result, params)
    else
      emit_next(result, snapshot, params)
    end
  end

  defp maybe_emit_queued_user_turn(result, %{queued_user_turn_signal: %Jido.Signal{} = signal}) do
    {:ok, Map.put(result, :queued_user_turn_signal, nil), [Actions.emit(signal)]}
  end

  defp maybe_emit_queued_user_turn(result, _params), do: {:ok, result}

  defp emit_next(result, snapshot, params) do
    directive =
      Actions.emit(snapshot.next_signal, %{
        chat_session_id: snapshot.chat_session_id,
        engine_session_ref: params.engine_session_ref,
        inference_opts: params.inference_opts,
        turn_message_id: snapshot.turn_message_id
      })

    {:ok, result, [directive]}
  end

  defp agent_status(%{turn_state: state})
       when state in [:no_pending_turn, :completed_turn, :failed_turn],
       do: :idle

  defp agent_status(_snapshot), do: :running

  defp queued_user_turn_signal(%{queued_user_turn_signal: %Jido.Signal{} = signal}, snapshot) do
    if snapshot.next_signal in [nil, Signals.noop()], do: nil, else: signal
  end

  defp queued_user_turn_signal(_params, _snapshot), do: nil
end
