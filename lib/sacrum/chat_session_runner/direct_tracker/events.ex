defmodule Sacrum.ChatSessionRunner.DirectTracker.Events do
  @moduledoc """
  Owns persisted public events for completed and rejected direct tracker operations.
  """

  alias Sacrum.Accounts.ChatEvents
  alias Sacrum.Chat.{DirectTrackerOperationResolver, Inference}
  alias Sacrum.ChatSessionRunner.DirectTracker.Rejections
  alias Sacrum.ChatSessionRunner.Session.Turn
  alias Sacrum.Repo.Schemas.{ChatEvent, ChatSession}

  @spec append_completed(ChatSession.t(), term(), term(), map()) ::
          {:ok, ChatEvent.t()} | {:error, term()}
  def append_completed(%ChatSession{} = session, operation, result, extra_public_payload)
      when is_map(extra_public_payload) do
    serialized_operation = DirectTrackerOperationResolver.serialize_resolution(operation)

    ChatEvents.append_to_session(session, %{
      event_type: "chat_direct_tracker_operation.completed",
      visibility: :public,
      public_payload:
        %{
          "action" => operation.action,
          "status" => "succeeded",
          "target" => DirectTrackerOperationResolver.public_target(serialized_operation),
          "result" => public_direct_tracker_result(result)
        }
        |> Map.merge(extra_public_payload)
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new(),
      internal_payload:
        Inference.scrub_secrets(%{
          "operation" => serialized_operation,
          "result" => stringify_direct_tracker_result(result)
        })
    })
  end

  @spec append_rejection(ChatSession.t(), Inference.Result.t(), String.t() | nil) ::
          {:ok, ChatEvent.t()} | {:error, term()}
  def append_rejection(
        %ChatSession{} = session,
        %Inference.Result{} = inference_result,
        turn_message_id
      ) do
    rejection =
      Map.fetch!(inference_result.internal_metadata, "direct_tracker_operation_rejected")

    reason = Rejections.public_reason(rejection)

    ChatEvents.append_to_session(session, %{
      event_type: "chat_direct_tracker_operation.rejected",
      visibility: :public,
      public_payload: %{
        "status" => "rejected",
        "reason" => reason,
        "message" => Rejections.public_message(reason, rejection),
        "turn_message_id" => turn_message_id || Turn.latest_user_message_id!(session)
      },
      internal_payload: Inference.scrub_secrets(%{"rejection" => rejection})
    })
  end

  @spec public_direct_tracker_result(term()) :: term()
  defp public_direct_tracker_result(%{section: section}) do
    section = stringify_direct_tracker_result(section)

    Map.take(section, ~w(id section_type section_order content done))
  end

  defp public_direct_tracker_result(%{workflow_step: step}),
    do: stringify_direct_tracker_result(step)

  defp public_direct_tracker_result(%{task: task}), do: stringify_direct_tracker_result(task)
  defp public_direct_tracker_result(result), do: stringify_direct_tracker_result(result)

  @spec stringify_direct_tracker_result(term()) :: term()
  defp stringify_direct_tracker_result(result) when is_map(result) do
    Map.new(result, fn {key, value} -> {to_string(key), stringify_direct_tracker_value(value)} end)
  end

  defp stringify_direct_tracker_result(result), do: result

  @spec stringify_direct_tracker_value(term()) :: term()
  defp stringify_direct_tracker_value(value) when is_map(value),
    do: stringify_direct_tracker_result(value)

  defp stringify_direct_tracker_value(value) when is_list(value),
    do: Enum.map(value, &stringify_direct_tracker_value/1)

  defp stringify_direct_tracker_value(value), do: value
end
