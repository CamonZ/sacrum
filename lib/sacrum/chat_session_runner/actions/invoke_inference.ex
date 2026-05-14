defmodule Sacrum.ChatSessionRunner.Actions.InvokeInference do
  @moduledoc """
  Calls the Sacrum inference boundary for a chat session and emits the
  append-assistant signal with the inference result attached.
  """

  use Jido.Action,
    name: "sacrum_chat_session_invoke_inference",
    description: "Invoke Sacrum chat inference for the persisted transcript",
    category: "chat",
    tags: ["sacrum", "chat", "session", "invoke_inference"],
    vsn: "1.0.0",
    schema: [
      chat_session_id: [type: :string, required: true],
      engine_session_ref: [type: :string, required: true],
      inference_opts: [type: :any, default: []]
    ]

  alias Sacrum.Accounts.ChatMessages
  alias Sacrum.ChatSessionRunner.Actions
  alias Sacrum.ChatSessionRunner.Actions.Failure
  alias Sacrum.ChatSessionRunner.Pipeline
  alias Sacrum.ChatSessionRunner.Signals
  alias Sacrum.Repo.Schemas.ChatMessage

  @impl true
  def run(params, _context) do
    with {:ok, session} <- Pipeline.fetch_session(params.chat_session_id),
         {:continue, session} <- Pipeline.ensure_runnable(session),
         {:ok, messages} <- ChatMessages.list_for_session(session, include_private: true),
         {:ok, session, result} <-
           Pipeline.invoke_inference(session, messages, params.inference_opts) do
      directive =
        Actions.emit(Signals.append_assistant(), %{
          chat_session_id: session.id,
          engine_session_ref: params.engine_session_ref,
          inference_opts: params.inference_opts,
          turn_message_id: turn_message_id(messages),
          inference_result: result
        })

      {:ok, %{step: :invoke_inference, chat_session_id: session.id}, [directive]}
    else
      {:halt, _session, reason} -> Failure.halt(params, reason)
      {:error, reason} -> Failure.fail(params, reason)
    end
  end

  defp turn_message_id(messages) do
    messages
    |> Enum.filter(&(&1.role == :user))
    |> List.last()
    |> case do
      %ChatMessage{id: id} -> id
      nil -> nil
    end
  end
end
