defmodule Sacrum.ChatCatalog.Payload do
  @moduledoc "Strict wire projection: local transcripts, Git data and inference bookkeeping are rejected."
  @metadata ~w(
    label title titleStatus titleConfidence titleUserMessageCount
    harness providerId model selectedModelId selectedReasoningEffort
    selectedSpeedTier selectedPersonality createdAt updatedAt
    providerResumeId providerParentResumeId threadTotalTokens messageCount
    hasUserMessage lifecycle status permissionMode entityLevel
  )
  @outer ~w(
    status metadata task_id parent_chat_id gate_execution_id gate_task_run_id
    classifications deleted
  )
  @strings ~w(
    label title titleStatus harness providerId model selectedModelId
    selectedReasoningEffort selectedSpeedTier selectedPersonality
    createdAt updatedAt providerResumeId providerParentResumeId
    lifecycle status permissionMode entityLevel
  )
  @counts ~w(titleUserMessageCount threadTotalTokens messageCount)
  @enums %{
    "harness" => ~w(claude codex),
    "titleStatus" => ~w(pending low_confidence generated manual),
    "lifecycle" => ~w(idle closed),
    "status" => ~w(open closed),
    "entityLevel" => ~w(epic ticket task),
    "permissionMode" => ~w(accept_edits auto bypass_permissions default dont_ask plan)
  }

  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(payload) when is_map(payload) do
    if keys?(payload, @outer) and metadata_valid?(Map.get(payload, "metadata", %{})) and
         Map.get(payload, "status", "idle") in ~w(idle working) and
         classifications_valid?(Map.get(payload, "classifications", [])) and links_valid?(payload) and
         is_boolean(Map.get(payload, "deleted", false)) and
         byte_size(Jason.encode!(payload)) <= 524_288 do
      :ok
    else
      {:error, "invalid catalog payload"}
    end
  end

  def validate(_), do: {:error, "invalid catalog payload"}

  defp metadata_valid?(metadata) when is_map(metadata),
    do: keys?(metadata, @metadata) and Enum.all?(metadata, &metadata_value?/1)

  defp metadata_valid?(_), do: false

  defp classifications_valid?(values) when is_list(values),
    do: length(values) <= 1024 and Enum.all?(values, &classification?/1)

  defp classifications_valid?(_), do: false

  defp links_valid?(payload),
    do:
      Enum.all?(~w(task_id gate_execution_id gate_task_run_id), &uuid?(Map.get(payload, &1))) and
        nullable_string?(Map.get(payload, "parent_chat_id"), 200)

  defp keys?(map, allowed), do: Enum.all?(Map.keys(map), &(&1 in allowed))
  defp nullable_string?(nil, _), do: true
  defp nullable_string?(v, max), do: is_binary(v) and byte_size(v) <= max
  defp uuid?(nil), do: true
  defp uuid?(v), do: match?({:ok, _}, Ecto.UUID.cast(v))

  defp metadata_value?({key, value}) when key in @counts,
    do: is_nil(value) or (is_integer(value) and value >= 0)

  defp metadata_value?({"titleConfidence", value}),
    do: is_nil(value) or (is_number(value) and value >= 0 and value <= 1)

  defp metadata_value?({"hasUserMessage", value}), do: is_boolean(value) or is_nil(value)

  defp metadata_value?({key, value}) when key in ["createdAt", "updatedAt"],
    do: is_nil(value) or (is_binary(value) and match?({:ok, _, _}, DateTime.from_iso8601(value)))

  defp metadata_value?({key, value}) when key in @strings do
    case Map.get(@enums, key) do
      nil -> nullable_string?(value, 1024)
      values -> is_nil(value) or value in values
    end
  end

  defp metadata_value?(_), do: false
  defp hash?(v), do: is_binary(v) and Regex.match?(~r/\A[0-9a-f]{64}\z/, v)

  defp classification?(v) when is_map(v) do
    keys?(v, ~w(tool_id input_hash classifier_fingerprint labels)) and
      hash?(v["tool_id"]) and
      hash?(v["input_hash"]) and hash?(v["classifier_fingerprint"]) and
      is_list(v["labels"]) and length(v["labels"]) <= 64 and
      Enum.all?(v["labels"], &(is_binary(&1) and byte_size(&1) <= 1024))
  end

  defp classification?(_), do: false
end
