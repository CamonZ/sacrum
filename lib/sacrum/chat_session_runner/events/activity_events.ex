defmodule Sacrum.ChatSessionRunner.Events.ActivityEvents do
  @moduledoc """
  Builds client-safe public chat runner activity events.

  Activity events describe runner progress for clients. They are persisted as
  public `chat_events` only and must not be appended to the transcript as chat
  messages.
  """

  import Ecto.Query

  alias Sacrum.Accounts.ChatEvents
  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.ChatEvent
  alias Sacrum.Repo.Schemas.ChatSession

  @type details :: map()
  @type attrs :: %{
          event_type: String.t(),
          visibility: :public,
          public_payload: map(),
          internal_payload: map()
        }

  @metadata_key_pairs [
    {"turn_message_id", :turn_message_id},
    {"client_message_id", :client_message_id},
    {"provider", :provider},
    {"model", :model},
    {"tool_name", :tool_name},
    {"operation", :operation},
    {"display", :display}
  ]
  @string_metadata_keys ~w(turn_message_id client_message_id provider model tool_name operation)
  @display_key_pairs [{"label", :label}]

  @spec accepted_turn_attrs(ChatSession.t(), details()) :: attrs()
  def accepted_turn_attrs(%ChatSession{} = session, details) when is_map(details) do
    activity_attrs(session, "accepted_turn", "queued", details)
  end

  @spec ensure_accepted_turn(ChatSession.t(), details()) ::
          {:ok, ChatEvent.t()} | {:error, term()}
  def ensure_accepted_turn(%ChatSession{} = session, details) when is_map(details) do
    case activity_for_turn(
           session,
           "accepted_turn",
           fetch_detail(details, "turn_message_id", :turn_message_id)
         ) do
      {:ok, event} ->
        {:ok, event}

      {:error, :not_found} ->
        ChatEvents.append_to_session(session, accepted_turn_attrs(session, details))
    end
  end

  @spec invoking_model_attrs(ChatSession.t(), details()) :: attrs()
  def invoking_model_attrs(%ChatSession{} = session, details) when is_map(details) do
    activity_attrs(session, "invoking_model", "running", details)
  end

  @spec executing_tool_attrs(ChatSession.t(), details()) :: attrs()
  def executing_tool_attrs(%ChatSession{} = session, details) when is_map(details) do
    activity_attrs(session, "executing_tool", "running", details)
  end

  @spec applying_tracker_operation_attrs(ChatSession.t(), details()) :: attrs()
  def applying_tracker_operation_attrs(%ChatSession{} = session, details) when is_map(details) do
    activity_attrs(session, "applying_tracker_operation", "running", details)
  end

  @spec continuing_after_tool_result_attrs(ChatSession.t(), details()) :: attrs()
  def continuing_after_tool_result_attrs(%ChatSession{} = session, details)
      when is_map(details) do
    activity_attrs(session, "continuing_after_tool_result", "running", details)
  end

  @spec composing_answer_attrs(ChatSession.t(), details()) :: attrs()
  def composing_answer_attrs(%ChatSession{} = session, details) when is_map(details) do
    activity_attrs(session, "composing_answer", "running", details)
  end

  @spec completed_attrs(ChatSession.t(), details()) :: attrs()
  def completed_attrs(%ChatSession{} = session, details) when is_map(details) do
    activity_attrs(session, "completed", "completed", details)
  end

  @spec ensure_completed(ChatSession.t(), details()) :: {:ok, ChatEvent.t()} | {:error, term()}
  def ensure_completed(%ChatSession{} = session, details) when is_map(details) do
    case completed_for_turn(session, fetch_detail(details, "turn_message_id", :turn_message_id)) do
      {:ok, event} ->
        {:ok, event}

      {:error, :not_found} ->
        ChatEvents.append_to_session(session, completed_attrs(session, details))
    end
  end

  @spec failed_attrs(ChatSession.t(), details()) :: attrs()
  def failed_attrs(%ChatSession{} = session, details) when is_map(details) do
    activity_attrs(session, "failed", "failed", details)
  end

  defp activity_attrs(%ChatSession{} = session, phase, status, details) do
    public_payload =
      Map.merge(
        %{
          "chat_session_id" => session.id,
          "phase" => phase,
          "status" => status
        },
        public_fields(details)
      )

    %{
      event_type: "chat_runner_activity.#{phase}",
      visibility: :public,
      public_payload: public_payload,
      internal_payload: %{}
    }
  end

  defp completed_for_turn(%ChatSession{} = session, turn_message_id)
       when is_binary(turn_message_id) do
    activity_for_turn(session, "completed", turn_message_id)
  end

  defp completed_for_turn(%ChatSession{}, _turn_message_id), do: {:error, :not_found}

  defp activity_for_turn(%ChatSession{} = session, phase, turn_message_id)
       when is_binary(phase) and is_binary(turn_message_id) do
    session
    |> activity_for_turn_query(phase, turn_message_id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      event -> {:ok, event}
    end
  end

  defp activity_for_turn(%ChatSession{}, _phase, _turn_message_id), do: {:error, :not_found}

  defp activity_for_turn_query(%ChatSession{} = session, phase, turn_message_id) do
    from event in ChatEvent,
      where:
        event.user_id == ^session.user_id and event.project_id == ^session.project_id and
          event.chat_session_id == ^session.id and
          event.event_type == ^"chat_runner_activity.#{phase}" and
          event.visibility == :public and
          fragment("?->>'turn_message_id' = ?", event.public_payload, ^turn_message_id),
      order_by: [asc: event.inserted_at, asc: event.id],
      limit: 1
  end

  defp public_fields(details) do
    Enum.reduce(@metadata_key_pairs, %{}, fn {string_key, atom_key}, metadata ->
      case sanitize_metadata_value(string_key, fetch_detail(details, string_key, atom_key)) do
        nil -> metadata
        value -> Map.put(metadata, string_key, value)
      end
    end)
  end

  defp sanitize_metadata_value(_key, nil), do: nil

  defp sanitize_metadata_value(key, value)
       when key in @string_metadata_keys and is_binary(value) do
    value
  end

  defp sanitize_metadata_value("display", value) when is_map(value) do
    @display_key_pairs
    |> Enum.reduce(%{}, fn {string_key, atom_key}, display ->
      case fetch_detail(value, string_key, atom_key) do
        label when is_binary(label) -> Map.put(display, string_key, label)
        _other -> display
      end
    end)
    |> empty_to_nil()
  end

  defp sanitize_metadata_value(_key, _value), do: nil

  defp fetch_detail(details, string_key, atom_key) do
    cond do
      Map.has_key?(details, string_key) -> Map.fetch!(details, string_key)
      Map.has_key?(details, atom_key) -> Map.fetch!(details, atom_key)
      true -> nil
    end
  end

  defp empty_to_nil(map) when map == %{}, do: nil
  defp empty_to_nil(map), do: map
end
