defmodule Sacrum.ChatSessionRunner.DirectTracker.Runner do
  @moduledoc """
  Coordinates direct tracker execution from verified inference metadata.
  """

  alias Sacrum.Accounts.ChatEvents
  alias Sacrum.Chat.Inference
  alias Sacrum.ChatSessionRunner.DirectTracker.{Events, Operations}
  alias Sacrum.ChatSessionRunner.Events.ActivityEvents
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.{ChatEvent, ChatSession}

  @spec execute(ChatSession.t(), Inference.Result.t(), map()) ::
          {:ok, [ChatEvent.t()]} | {:error, term()}
  def execute(
        %ChatSession{} = session,
        %Inference.Result{} = inference_result,
        extra_public_payload
      )
      when is_map(extra_public_payload) do
    with {:ok, operations} <- Operations.direct_tracker_operations(inference_result) do
      execute(session, operations, extra_public_payload)
    end
  end

  @spec execute(ChatSession.t(), [term()], map()) :: {:ok, [ChatEvent.t()]} | {:error, term()}
  def execute(%ChatSession{} = session, operations, extra_public_payload)
      when is_list(operations) and is_map(extra_public_payload) do
    Repo.transaction(fn ->
      case do_execute(
             operations,
             session,
             extra_public_payload,
             completed_events_by_tool_call(session, operations, extra_public_payload)
           ) do
        {:ok, events} -> Enum.reverse(events)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @spec maybe_execute(ChatSession.t(), Inference.Result.t(), String.t(), String.t()) ::
          {:ok, [ChatEvent.t()]} | {:error, term()}
  def maybe_execute(
        %ChatSession{} = session,
        %Inference.Result{} = inference_result,
        assistant_message_id,
        turn_message_id
      )
      when is_binary(assistant_message_id) and is_binary(turn_message_id) do
    case Operations.direct_tracker_operations(inference_result) do
      {:error, :not_found} ->
        {:ok, []}

      {:ok, operations} ->
        execute(session, operations, %{
          "assistant_message_id" => assistant_message_id,
          "turn_message_id" => turn_message_id
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec do_execute([term()], ChatSession.t(), map(), map()) ::
          {:ok, [ChatEvent.t()]} | {:error, term()}
  defp do_execute(operations, %ChatSession{} = session, extra_public_payload, completed_events) do
    Enum.reduce_while(operations, {:ok, []}, fn operation, {:ok, events} ->
      case execute_one(session, operation, extra_public_payload, completed_events) do
        {:ok, event} -> {:cont, {:ok, [event | events]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec execute_one(ChatSession.t(), term(), map(), map()) ::
          {:ok, ChatEvent.t()} | {:error, term()}
  defp execute_one(%ChatSession{} = session, operation, extra_public_payload, completed_events) do
    case completed_event_for_tool_call(operation, completed_events) do
      {:ok, event} ->
        {:ok, event}

      :error ->
        with {:ok, _executing_event} <-
               append_activity(session, operation, extra_public_payload, :executing_tool),
             {:ok, result} <- executor().execute(operation),
             {:ok, _applying_event} <-
               append_activity(
                 session,
                 operation,
                 extra_public_payload,
                 :applying_tracker_operation
               ) do
          Events.append_completed(session, operation, result, extra_public_payload)
        end
    end
  end

  defp append_activity(%ChatSession{} = session, operation, extra_public_payload, phase)
       when phase in [:executing_tool, :applying_tracker_operation] do
    details =
      extra_public_payload
      |> Map.take(["turn_message_id", "assistant_message_id"])
      |> Map.merge(%{
        "tool_name" => tool_name(operation),
        "operation" => operation_name(operation),
        "display" => %{"label" => activity_label(phase)}
      })

    attrs =
      case phase do
        :executing_tool ->
          ActivityEvents.executing_tool_attrs(session, details)

        :applying_tracker_operation ->
          ActivityEvents.applying_tracker_operation_attrs(session, details)
      end

    ChatEvents.append_to_session(session, attrs)
  end

  defp tool_name(%{tool_name: tool_name}) when is_binary(tool_name), do: tool_name
  defp tool_name(%{tool_call: %{"function" => %{"name" => name}}}) when is_binary(name), do: name
  defp tool_name(_operation), do: nil

  defp operation_name(%{action: action}) when is_atom(action), do: Atom.to_string(action)
  defp operation_name(%{action: action}) when is_binary(action), do: action
  defp operation_name(_operation), do: nil

  defp activity_label(:executing_tool), do: "Executing tool"
  defp activity_label(:applying_tracker_operation), do: "Applying tracker operation"

  defp executor do
    Application.get_env(
      :sacrum,
      :direct_tracker_operation_executor,
      Sacrum.Chat.DirectTrackerOperationExecutor
    )
  end

  defp completed_events_by_tool_call(
         %ChatSession{} = session,
         operations,
         %{"turn_message_id" => turn_message_id}
       )
       when is_binary(turn_message_id) do
    Events.completed_events_by_tool_call(session, operations, turn_message_id)
  end

  defp completed_events_by_tool_call(_session, _operations, _extra_public_payload), do: %{}

  defp completed_event_for_tool_call(operation, completed_events) do
    case Events.tool_call_id(operation) do
      nil -> :error
      id -> Map.fetch(completed_events, id)
    end
  end
end
