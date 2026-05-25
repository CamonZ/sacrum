defmodule Sacrum.ChatSessionRunner.DirectTracker.Rejections do
  @moduledoc """
  Shapes public direct tracker rejection reasons and messages.
  """

  @valid_tracker_target_instruction "Select a valid in-scope task, workflow, section, or workflow step"

  @spec public_reason(map()) :: String.t()
  def public_reason(%{"reason_code" => reason})
      when reason in ["ambiguous_target", "out_of_scope"],
      do: reason

  def public_reason(_rejection), do: "out_of_scope"

  @spec public_message(String.t(), map()) :: String.t()
  def public_message("ambiguous_target", rejection) do
    case ambiguous_target_handle(rejection) do
      nil ->
        "Multiple tracker objects match that reference. #{@valid_tracker_target_instruction}."

      handle ->
        "Multiple tracker objects match #{handle}. #{@valid_tracker_target_instruction}."
    end
  end

  def public_message(_reason, _rejection) do
    "#{@valid_tracker_target_instruction} and try the tracker update again."
  end

  @spec ambiguous_target_handle(map()) :: String.t() | nil
  defp ambiguous_target_handle(%{"details" => details}) when is_binary(details) do
    details
    |> then(
      &Regex.scan(
        ~r/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i,
        &1
      )
    )
    |> Enum.map(fn [id] -> String.slice(id, 0, 8) end)
    |> Enum.uniq()
    |> case do
      [handle] -> handle
      _other -> nil
    end
  end

  defp ambiguous_target_handle(_rejection), do: nil
end
