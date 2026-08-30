defmodule Sacrum.Orchestrator.StructuredOutput do
  @moduledoc """
  Decodes structured output as raw JSON.
  """

  @spec decode(binary()) :: {:ok, term()} | {:error, :invalid_json}
  def decode(output) when is_binary(output) do
    case Jason.decode(output) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end
end
