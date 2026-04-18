defmodule Sacrum.Orchestrator.StructuredOutputTest do
  use ExUnit.Case, async: true

  alias Sacrum.Orchestrator.StructuredOutput

  describe "decode/1 — fenced JSON" do
    test "strips leading and trailing markdown fences with language tag" do
      input = "```json\n{\"key\": \"value\"}\n```"
      assert {:ok, decoded} = StructuredOutput.decode(input)
      assert decoded == %{"key" => "value"}
    end

    test "strips leading and trailing markdown fences without language tag" do
      input = "```\n{\"key\": \"value\"}\n```"
      assert {:ok, decoded} = StructuredOutput.decode(input)
      assert decoded == %{"key" => "value"}
    end

    test "strips fences with whitespace variations" do
      input = "  ```json  \n{\"x\": 1}\n  ```  \n"
      assert {:ok, decoded} = StructuredOutput.decode(input)
      assert decoded == %{"x" => 1}
    end
  end

  describe "decode/1 — non-fenced JSON" do
    test "decodes plain JSON object without fences" do
      input = "{\"key\": \"value\"}"
      assert {:ok, decoded} = StructuredOutput.decode(input)
      assert decoded == %{"key" => "value"}
    end

    test "decodes plain JSON array without fences" do
      input = "[1, 2, 3]"
      assert {:ok, decoded} = StructuredOutput.decode(input)
      assert decoded == [1, 2, 3]
    end

    test "decodes plain JSON with nested structure" do
      input = "{\"outer\": {\"inner\": [1, 2, 3]}}"
      assert {:ok, decoded} = StructuredOutput.decode(input)
      assert decoded == %{"outer" => %{"inner" => [1, 2, 3]}}
    end
  end

  describe "decode/1 — mangled fences" do
    test "strips only opening fence when closing fence is missing" do
      input = "```json\n{\"key\": \"value\"}"
      assert {:ok, decoded} = StructuredOutput.decode(input)
      assert decoded == %{"key" => "value"}
    end

    test "strips only closing fence when opening fence is missing" do
      input = "{\"key\": \"value\"}\n```"
      assert {:ok, decoded} = StructuredOutput.decode(input)
      assert decoded == %{"key" => "value"}
    end

    test "returns error for non-JSON content" do
      input = "```\nThis is not JSON\n```"
      assert {:error, :invalid_json} = StructuredOutput.decode(input)
    end

    test "returns error for malformed JSON in fences" do
      input = "```json\n{\"key\": value}\n```"
      assert {:error, :invalid_json} = StructuredOutput.decode(input)
    end
  end

  describe "decode/1 — edge cases" do
    test "handles empty object" do
      input = "```json\n{}\n```"
      assert {:ok, decoded} = StructuredOutput.decode(input)
      assert decoded == %{}
    end

    test "handles null value" do
      input = "```json\nnull\n```"
      assert {:ok, decoded} = StructuredOutput.decode(input)
      assert decoded == nil
    end

    test "handles boolean values" do
      input = "```json\ntrue\n```"
      assert {:ok, decoded} = StructuredOutput.decode(input)
      assert decoded == true
    end

    test "handles numeric values" do
      input = "```json\n42\n```"
      assert {:ok, decoded} = StructuredOutput.decode(input)
      assert decoded == 42
    end

    test "handles string values" do
      input = "```json\n\"hello\"\n```"
      assert {:ok, decoded} = StructuredOutput.decode(input)
      assert decoded == "hello"
    end

    test "returns error for completely invalid input" do
      input = "not json at all"
      assert {:error, :invalid_json} = StructuredOutput.decode(input)
    end

    test "handles language tag variations" do
      input = "```yaml\n{\"key\": \"value\"}\n```"
      assert {:ok, decoded} = StructuredOutput.decode(input)
      assert decoded == %{"key" => "value"}
    end

    test "handles fence with multiple newlines" do
      input = "```json\n\n{\"key\": \"value\"}\n\n```"
      assert {:ok, decoded} = StructuredOutput.decode(input)
      assert decoded == %{"key" => "value"}
    end
  end
end
