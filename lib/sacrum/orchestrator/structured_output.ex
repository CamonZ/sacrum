defmodule Sacrum.Orchestrator.StructuredOutput do
  @moduledoc """
  Decodes structured output from the Claude Code CLI.

  The CLI wraps JSON in ```json ... ``` markdown fences even when invoked
  with --json-schema, so we strip optional leading/trailing fences before
  decoding.
  """

  # Non-greedy [\s\S]*? tolerates preamble before the opening fence; /s on the
  # trailing fence tolerates text after the closing fence.
  @leading_fence ~r/^[\s\S]*?```[^\n]*\n/
  @trailing_fence ~r/\n\s*```.*$/s

  @spec decode(binary()) :: {:ok, term()} | {:error, :invalid_json}
  def decode(output) when is_binary(output) do
    case Jason.decode(strip_fences(output)) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  @spec strip_fences(binary()) :: binary()
  def strip_fences(output) when is_binary(output) do
    without_leading = Regex.replace(@leading_fence, output, "")
    Regex.replace(@trailing_fence, without_leading, "")
  end
end
