defmodule Sacrum.Orchestrator.StructuredOutputTest do
  use ExUnit.Case, async: true

  alias Sacrum.Orchestrator.StructuredOutput

  describe "decode/1" do
    test "decodes plain JSON object" do
      input = "{\"key\": \"value\"}"
      assert {:ok, decoded} = StructuredOutput.decode(input)
      assert decoded == %{"key" => "value"}
    end

    test "decodes plain JSON array" do
      input = "[1, 2, 3]"
      assert {:ok, decoded} = StructuredOutput.decode(input)
      assert decoded == [1, 2, 3]
    end

    test "decodes plain JSON with nested structure" do
      input = "{\"outer\": {\"inner\": [1, 2, 3]}}"
      assert {:ok, decoded} = StructuredOutput.decode(input)
      assert decoded == %{"outer" => %{"inner" => [1, 2, 3]}}
    end

    test "decodes valid JSON containing Markdown fence text in a nested string" do
      fence_text = "```json\n{\"key\": \"value\"}\n```"
      input = Jason.encode!(%{"content" => fence_text})

      assert {:ok, decoded} = StructuredOutput.decode(input)
      assert decoded == %{"content" => fence_text}
    end

    test "returns an error for malformed JSON" do
      assert {:error, :invalid_json} = StructuredOutput.decode("{\"key\": value}")
    end

    test "returns an error for markdown-fenced JSON" do
      input = "```json\n{\"key\": \"value\"}\n```"
      assert {:error, :invalid_json} = StructuredOutput.decode(input)
    end

    test "returns an error for a preamble before JSON" do
      input = "Analysis:\n{\"key\": \"value\"}"
      assert {:error, :invalid_json} = StructuredOutput.decode(input)
    end

    test "returns an error for trailing prose after JSON" do
      input = "{\"key\": \"value\"}\nThat's the result."
      assert {:error, :invalid_json} = StructuredOutput.decode(input)
    end
  end
end
