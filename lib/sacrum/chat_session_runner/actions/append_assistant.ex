defmodule Sacrum.ChatSessionRunner.Actions.AppendAssistant do
  @moduledoc """
  Persists the assistant message and inference-completed internal event, then
  emits the complete-session signal.
  """

  use Jido.Action,
    name: "sacrum_chat_session_append_assistant",
    description: "Append the assistant message and inference completed event",
    category: "chat",
    tags: ["sacrum", "chat", "session", "append_assistant"],
    vsn: "1.0.0",
    schema: [
      chat_session_id: [type: :string, required: true],
      engine_session_ref: [type: :string, required: true],
      inference_opts: [type: :any, default: []],
      turn_message_id: [type: :string],
      inference_result: [type: :any, required: true]
    ]

  alias Sacrum.Chat.Inference.Result
  alias Sacrum.ChatSessionRunner.Actions
  alias Sacrum.ChatSessionRunner.Actions.Failure
  alias Sacrum.ChatSessionRunner.Pipeline
  alias Sacrum.ChatSessionRunner.Signals

  @impl true
  def run(params, _context) do
    with :ok <- validate_result(params.inference_result),
         {:ok, session} <- Pipeline.fetch_session(params.chat_session_id),
         {:continue, session} <- Pipeline.ensure_runnable(session),
         {:ok, _message} <-
           Pipeline.append_assistant_message(
             session,
             params.inference_result,
             Map.get(params, :turn_message_id)
           ) do
      directive =
        Actions.emit(Signals.complete_session(), %{
          chat_session_id: session.id,
          engine_session_ref: params.engine_session_ref,
          inference_opts: params.inference_opts,
          turn_message_id: Map.get(params, :turn_message_id)
        })

      {:ok, %{step: :append_assistant, chat_session_id: session.id}, [directive]}
    else
      {:halt, _session, reason} -> Failure.halt(params, reason)
      {:error, reason} -> Failure.fail(params, reason)
    end
  end

  @spec validate_result(term()) :: :ok | {:error, :invalid_inference_result_payload}
  defp validate_result(%Result{}), do: :ok
  defp validate_result(_other), do: {:error, :invalid_inference_result_payload}
end
