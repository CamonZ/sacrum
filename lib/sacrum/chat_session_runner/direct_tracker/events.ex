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
    serialized_result = serialize_result(result)

    ChatEvents.append_to_session(session, %{
      event_type: "chat_direct_tracker_operation.completed",
      visibility: :public,
      public_payload:
        %{
          "action" => operation.action,
          "status" => "succeeded",
          "target" => DirectTrackerOperationResolver.public_target(serialized_operation),
          "result" => public_direct_tracker_result(serialized_result)
        }
        |> Map.merge(extra_public_payload)
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new(),
      internal_payload:
        Inference.scrub_secrets(%{
          "operation" => serialized_operation,
          "result" => serialized_result
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

  @doc false
  @spec serialize_result(term()) :: term()
  def serialize_result(%DateTime{} = value), do: DateTime.to_iso8601(value)

  def serialize_result(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def serialize_result(%Date{} = value), do: Date.to_iso8601(value)
  def serialize_result(%Time{} = value), do: Time.to_iso8601(value)
  def serialize_result(%Decimal{} = value), do: Decimal.to_string(value)
  def serialize_result(%_struct{} = value), do: inspect(value)

  def serialize_result(result) when is_map(result) do
    Map.new(result, fn {key, value} -> {to_string(key), serialize_result(value)} end)
  end

  def serialize_result(result) when is_list(result), do: Enum.map(result, &serialize_result/1)

  def serialize_result(result) when is_tuple(result),
    do: result |> Tuple.to_list() |> serialize_result()

  def serialize_result(value) when is_atom(value) and not is_boolean(value) and not is_nil(value),
    do: Atom.to_string(value)

  def serialize_result(value)
      when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value

  def serialize_result(value), do: inspect(value)

  @spec public_direct_tracker_result(term()) :: term()
  defp public_direct_tracker_result(%{"section" => section}) do
    Map.take(section, ~w(id section_type section_order content done))
  end

  defp public_direct_tracker_result(%{"workflow_step" => step}), do: step

  defp public_direct_tracker_result(%{"task" => task}), do: task
  defp public_direct_tracker_result(result), do: result
end
