defmodule Sacrum.Orchestrator.ExecutionConfigTest do
  use ExUnit.Case, async: true

  alias Sacrum.Orchestrator.{ExecutionConfig, PromptContext, PromptRenderer, ScriptRenderer}
  alias Sacrum.Repo.Schemas.WorkflowStep
  alias Sacrum.Repo.Schemas.WorkflowStep.Config

  test "execute snapshots the entire typed context unchanged and renders only its script" do
    output = %{
      "name" => "example",
      "quantity" => 3,
      "unit_price" => 12,
      "active" => false,
      "nothing" => nil,
      "values" => [3, true, nil],
      "text" => "quote\"\n\\{{ literal.data }}"
    }

    context = %{
      "steps" => %{"prepare" => %{"output" => output}},
      "execution" => %{"previous_output" => output, "run_count" => 2},
      "task" => %{"sections" => %{"context" => ["notes"]}, "code_references" => []},
      "inputs" => %{"empty" => "", "nothing" => nil, "false" => false},
      "workflow" => %{"name" => "Execute"},
      "artifacts" => %{"task" => %{"result" => %{"id" => "artifact-id"}}}
    }

    script =
      "// attempt {{ execution.run_count }}\n" <>
        "transform(execution.previous_output)"

    expected_script =
      "// attempt 2\ntransform(execution.previous_output)"

    config = %Config.Execute{script: script, output_schema: %{"type" => "object"}}
    assert {:ok, rendered} = ExecutionConfig.render(%WorkflowStep{config: config}, context)
    assert rendered.context === context
    assert rendered.script == expected_script
    assert rendered.output_schema == config.output_schema
  end

  test "strict script rendering reports parse, variable, filter, and source interpolation failures" do
    for script <- [
          "{% if task.title %}",
          "{{ missing.variable }}",
          "{{ task.title | nonexistent }}",
          "{% if false %}input{% endif %}"
        ] do
      assert {:error, %{code: :step_config_render_failed, path: "$.script", message: message}} =
               ScriptRenderer.render(script, %{"task" => %{"title" => "Task"}})

      assert is_binary(message) and message != ""
    end

    for output <- [%{"total" => 36}, [36]] do
      for template <- [
            "{{ value }}",
            "{% echo value %}",
            "{% cycle value %}",
            "{% if false %}ok{% elsif true %}{{ value }}{% endif %}"
          ] do
        assert {:error, %{path: "$.script", message: message}} =
                 ScriptRenderer.render(template, %{"value" => output})

        assert message =~ "available in context"
      end
    end

    assert {:ok, "1;2;"} =
             ScriptRenderer.render("{% for value in values %}{{ value }};{% endfor %}", %{
               "values" => [1, 2]
             })

    assert {:ok, "Task"} =
             ScriptRenderer.render("{% echo task.title %}", %{"task" => %{"title" => "Task"}})

    assert {:ok, "36"} = ScriptRenderer.render("{% cycle number %}", %{"number" => 36})
    assert {:ok, "{% if task.title %}"} = PromptRenderer.render("{% if task.title %}", %{})
    assert {:ok, ""} = PromptRenderer.render("{{ missing.variable }}", %{})
  end

  test "typed previous output distinguishes missing from JSON null and scalars for any consumer" do
    for output <- [nil, false, true, 36, 1.5, [], %{}] do
      context = PromptContext.build_execution_context(%{previous: %{output: output}})
      assert Map.fetch!(context, "previous_output") == output
      config = %Config.StructuredInference{state: "{{ execution.previous_output }}"}

      assert {:ok, rendered} =
               ExecutionConfig.render(%WorkflowStep{config: config}, %{"execution" => context})

      assert rendered.state == output
    end

    refute Map.has_key?(PromptContext.build_execution_context(%{}), "previous_output")
  end

  test "whole context and rendered source bounds reject expansion before snapshotting" do
    config = %Config.Execute{script: "transform(execution.previous_output)", output_schema: %{}}

    for value <- [
          Enum.to_list(1..4097),
          String.duplicate("x", 1_048_577),
          Enum.reduce(1..33, nil, fn _, value -> [value] end)
        ] do
      assert {:error, %{path: path, message: message}} =
               ExecutionConfig.render(%WorkflowStep{config: config}, %{"value" => value})

      assert String.starts_with?(path, "$.context")
      assert message =~ "at most"
    end

    assert {:error, %{path: "$.script", message: message}} =
             ScriptRenderer.render("{{ value }}", %{"value" => String.duplicate("x", 262_145)})

    assert message =~ "262144 bytes"
  end

  test "context rejects non-JSON roots, keys, and values with precise paths" do
    for value <- [nil, false, [], ""] do
      assert {:error, %{path: "$.context", message: "must be a JSON object"}} =
               Config.Execute.validate_context(value)
    end

    assert {:error, %{path: "$.context", message: "must use string keys"}} =
             Config.Execute.validate_context(%{unexpected: 1})

    for value <- [:unexpected, self(), %URI{path: "/private"}] do
      assert {:error, %{path: "$.context.value"}} =
               Config.Execute.validate_context(%{"value" => value})
    end

    key = "items.with.\"quotes\""

    assert {:error, %{path: path, message: "must have at most 4096 entries"}} =
             Config.Execute.validate_context(%{key => Enum.to_list(1..4097)})

    assert path == "$.context[#{inspect(key)}]"
  end

  test "LLM previous-output interpolation and Liquid conditions retain legacy semantics" do
    for template <- [
          "{{ execution.previous_output }}",
          "{% if execution.previous_output %}yes{% else %}no{% endif %}",
          "{% if execution.previous_output == empty %}empty{% else %}value{% endif %}"
        ] do
      for {data, legacy_output} <- [
            {%{}, ""},
            {%{previous: %{output: nil}}, ""},
            {%{previous: %{output: false}}, ""},
            {%{previous: %{output: 36}}, "36"}
          ] do
        {:ok, parsed} = Solid.parse(template)

        {:ok, legacy, []} =
          Solid.render(parsed, %{"execution" => %{"previous_output" => legacy_output}})

        context = %{"execution" => PromptContext.build_execution_context(data)}
        assert {:ok, IO.iodata_to_binary(legacy)} == PromptRenderer.render(template, context)
      end
    end
  end
end
