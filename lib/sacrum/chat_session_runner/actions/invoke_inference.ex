defmodule Sacrum.ChatSessionRunner.Actions.InvokeInference do
  @moduledoc """
  Calls the Sacrum inference boundary for a chat session and emits the
  verify-authoring signal with the inference result attached.

  Before delegating to `Pipeline.invoke_inference/3`, this action enriches the
  caller-provided `inference_opts` with the authoring system prompt and the
  `start_authoring`/`revise_authoring` tool specs plus direct tracker operation
  specs so the producer side of the authoring loop is actually wired through to
  the LLM. Callers may still override either option (tests inject `:provider`,
  for example, and may pass their own `:system_prompt` or `:tools`).
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

  alias Sacrum.Accounts.{AuthoringDrafts, ChatMessages}
  alias Sacrum.Chat.{AuthoringSystemPrompt, AuthoringTools, DirectTrackerOperationTools}
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
         turn_message_id = turn_message_id(messages),
         {:ok, session, result} <-
           Pipeline.invoke_inference(
             session,
             messages,
             enrich_inference_opts(session, messages, params.inference_opts, turn_message_id)
           ) do
      directive =
        Actions.emit(Signals.verify_authoring(), %{
          chat_session_id: session.id,
          engine_session_ref: params.engine_session_ref,
          inference_opts: params.inference_opts,
          turn_message_id: turn_message_id,
          inference_result: result
        })

      {:ok, %{step: :invoke_inference, chat_session_id: session.id}, [directive]}
    else
      {:halt, _session, reason} -> Failure.halt(params, reason)
      {:error, reason} -> Failure.fail(params, reason)
    end
  end

  defp enrich_inference_opts(session, messages, inference_opts, turn_message_id)
       when is_list(inference_opts) do
    inference_opts
    |> put_new_system_prompt(session, messages)
    |> put_new_tools()
    |> maybe_put_new_source_message_id(turn_message_id)
  end

  defp put_new_system_prompt(inference_opts, session, messages) do
    if Keyword.has_key?(inference_opts, :system_prompt) do
      inference_opts
    else
      active_draft = AuthoringDrafts.get_latest_for_chat_session(session)
      user_turn_count = Enum.count(messages, &(&1.role == :user))

      system_prompt =
        AuthoringSystemPrompt.build(%{
          active_draft: active_draft,
          user_turn_count: user_turn_count
        })

      Keyword.put(inference_opts, :system_prompt, system_prompt)
    end
  end

  defp put_new_tools(inference_opts) do
    if Keyword.has_key?(inference_opts, :tools) do
      inference_opts
    else
      Keyword.put(
        inference_opts,
        :tools,
        AuthoringTools.all() ++ DirectTrackerOperationTools.all()
      )
    end
  end

  defp maybe_put_new_source_message_id(opts, nil), do: opts

  defp maybe_put_new_source_message_id(opts, message_id) when is_binary(message_id),
    do: Keyword.put_new(opts, :source_message_id, message_id)

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
