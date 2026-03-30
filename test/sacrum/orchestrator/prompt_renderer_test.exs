defmodule Sacrum.Orchestrator.PromptRendererTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Sacrum.Orchestrator.PromptRenderer

  describe "render/2 - plain text" do
    test "plain text without Liquid syntax renders unchanged" do
      template = "This is plain text without any syntax"
      context = %{}

      assert {:ok, result} = PromptRenderer.render(template, context)
      assert result == template
    end

    test "plain text with special characters renders unchanged" do
      template = "Text with special chars: @#$%^&*()"
      context = %{}

      assert {:ok, result} = PromptRenderer.render(template, context)
      assert result == template
    end
  end

  describe "render/2 - variable interpolation" do
    test "{{ name }} resolves to context value" do
      template = "Hello {{ name }}!"
      context = %{"name" => "Alice"}

      assert {:ok, result} = PromptRenderer.render(template, context)
      assert result == "Hello Alice!"
    end

    test "multiple variables in one template" do
      template = "{{ greeting }}, {{ name }}! You are {{ age }} years old."
      context = %{"greeting" => "Hello", "name" => "Bob", "age" => "25"}

      assert {:ok, result} = PromptRenderer.render(template, context)
      assert result == "Hello, Bob! You are 25 years old."
    end

    test "numeric values are converted to strings" do
      template = "The answer is {{ number }}"
      context = %{"number" => 42}

      assert {:ok, result} = PromptRenderer.render(template, context)
      assert result == "The answer is 42"
    end
  end

  describe "render/2 - nested map access" do
    test "nested access like {{ task.title }} with string-keyed map" do
      template = "Task: {{ task.title }}"
      context = %{"task" => %{"title" => "Fix bug"}}

      assert {:ok, result} = PromptRenderer.render(template, context)
      assert result == "Task: Fix bug"
    end

    test "deeply nested map access" do
      template = "{{ user.profile.name }}"
      context = %{"user" => %{"profile" => %{"name" => "Charlie"}}}

      assert {:ok, result} = PromptRenderer.render(template, context)
      assert result == "Charlie"
    end

    test "nested access with missing key returns raw template in strict mode" do
      template = "{{ task.missing }}"
      context = %{"task" => %{"title" => "Fix"}}

      assert {:ok, result} = PromptRenderer.render(template, context)
      assert result == template
    end
  end

  describe "render/2 - loops" do
    test "{% for item in items %} iterates correctly" do
      template = "{% for item in items %}{{ item }} {% endfor %}"
      context = %{"items" => ["a", "b", "c"]}

      assert {:ok, result} = PromptRenderer.render(template, context)
      assert result == "a b c "
    end

    test "for loop with nested variables" do
      template = "{% for task in tasks %}{{ task.title }}\n{% endfor %}"
      context = %{"tasks" => [%{"title" => "Task 1"}, %{"title" => "Task 2"}]}

      assert {:ok, result} = PromptRenderer.render(template, context)
      assert result == "Task 1\nTask 2\n"
    end

    test "for loop with forloop.index" do
      template = "{% for item in items %}{{ forloop.index }}: {{ item }} {% endfor %}"
      context = %{"items" => ["x", "y"]}

      assert {:ok, result} = PromptRenderer.render(template, context)
      assert result == "1: x 2: y "
    end
  end

  describe "render/2 - conditionals" do
    test "{% if condition %} evaluates true" do
      template = "{% if show %}Hello{% endif %}"
      context = %{"show" => true}

      assert {:ok, result} = PromptRenderer.render(template, context)
      assert result == "Hello"
    end

    test "{% if condition %} evaluates false" do
      template = "{% if show %}Hello{% else %}Goodbye{% endif %}"
      context = %{"show" => false}

      assert {:ok, result} = PromptRenderer.render(template, context)
      assert result == "Goodbye"
    end

    test "if with comparison operators" do
      template = "{% if count > 5 %}Many{% else %}Few{% endif %}"
      context = %{"count" => 10}

      assert {:ok, result} = PromptRenderer.render(template, context)
      assert result == "Many"
    end

    test "if with string comparison" do
      template = "{% if status == \"active\" %}Active{% else %}Inactive{% endif %}"
      context = %{"status" => "active"}

      assert {:ok, result} = PromptRenderer.render(template, context)
      assert result == "Active"
    end
  end

  describe "render/2 - filters" do
    test "upcase filter" do
      template = "{{ text | upcase }}"
      context = %{"text" => "hello"}

      assert {:ok, result} = PromptRenderer.render(template, context)
      assert result == "HELLO"
    end

    test "downcase filter" do
      template = "{{ text | downcase }}"
      context = %{"text" => "HELLO"}

      assert {:ok, result} = PromptRenderer.render(template, context)
      assert result == "hello"
    end

    test "size filter" do
      template = "Length: {{ items | size }}"
      context = %{"items" => [1, 2, 3, 4, 5]}

      assert {:ok, result} = PromptRenderer.render(template, context)
      assert result == "Length: 5"
    end

    test "join filter" do
      template = "{{ items | join: \", \" }}"
      context = %{"items" => ["apple", "banana", "cherry"]}

      assert {:ok, result} = PromptRenderer.render(template, context)
      assert result == "apple, banana, cherry"
    end
  end

  describe "render/2 - strict mode errors" do
    test "undefined variable logs warning and returns raw template" do
      template = "Hello {{ undefined_var }}"
      context = %{"other" => "value"}

      assert capture_log(fn ->
               assert {:ok, ^template} = PromptRenderer.render(template, context)
             end) =~ "Solid render error"
    end

    test "multiple undefined variables" do
      template = "{{ a }} and {{ b }}"
      context = %{}

      assert capture_log(fn ->
               assert {:ok, ^template} = PromptRenderer.render(template, context)
             end) =~ "Solid render error"
    end
  end

  describe "render/2 - parse errors" do
    test "malformed Liquid syntax logs warning and returns raw template" do
      template = "{% if unclosed %}"
      context = %{}

      assert capture_log(fn ->
               assert {:ok, ^template} = PromptRenderer.render(template, context)
             end) =~ "Solid parse error"
    end

    test "incomplete for loop" do
      template = "{% for item in items %}"
      context = %{"items" => []}

      assert capture_log(fn ->
               assert {:ok, ^template} = PromptRenderer.render(template, context)
             end) =~ "Solid parse error"
    end
  end

  describe "render/2 - edge cases" do
    test "nil template returns empty string" do
      assert {:ok, result} = PromptRenderer.render(nil, %{})
      assert result == ""
    end

    test "empty string template returns empty string" do
      assert {:ok, result} = PromptRenderer.render("", %{})
      assert result == ""
    end

    test "template with only whitespace" do
      template = "   \n\t   "
      context = %{}

      assert {:ok, result} = PromptRenderer.render(template, context)
      assert result == template
    end

    test "empty context map" do
      template = "Plain text"
      context = %{}

      assert {:ok, result} = PromptRenderer.render(template, context)
      assert result == template
    end
  end

  describe "render/2 - complex combinations" do
    test "for loop with if inside" do
      template = "{% for item in items %}{% if item.active %}{{ item.name }} {% endif %}{% endfor %}"
      context = %{
        "items" => [
          %{"name" => "Item1", "active" => true},
          %{"name" => "Item2", "active" => false},
          %{"name" => "Item3", "active" => true}
        ]
      }

      assert {:ok, result} = PromptRenderer.render(template, context)
      assert result == "Item1 Item3 "
    end

    test "multiline template with multiple constructs" do
      template =
        "Tasks for {{ user }}:\n{% for task in tasks %}\n- {{ task.title }} ({{ task.status }})\n{% endfor %}\n"

      context = %{
        "user" => "Alice",
        "tasks" => [
          %{"title" => "Task A", "status" => "done"},
          %{"title" => "Task B", "status" => "pending"}
        ]
      }

      assert {:ok, result} = PromptRenderer.render(template, context)
      assert result == "Tasks for Alice:\n\n- Task A (done)\n\n- Task B (pending)\n\n"
    end

    test "nested for loops" do
      template =
        "{% for section in sections %}\nSection: {{ section.name }}\n{% for item in section.items %}\n  - {{ item }}\n{% endfor %}\n{% endfor %}\n"

      context = %{
        "sections" => [
          %{"name" => "A", "items" => ["a1", "a2"]},
          %{"name" => "B", "items" => ["b1"]}
        ]
      }

      assert {:ok, result} = PromptRenderer.render(template, context)

      assert result ==
               "\nSection: A\n\n  - a1\n\n  - a2\n\n\nSection: B\n\n  - b1\n\n\n"
    end
  end

end
