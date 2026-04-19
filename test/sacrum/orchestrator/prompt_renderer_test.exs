defmodule Sacrum.Orchestrator.PromptRendererTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Sacrum.Orchestrator.{PromptContext, PromptRenderer}

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

    test "nested access with missing key renders as empty" do
      template = "before {{ task.missing }} after"
      context = %{"task" => %{"title" => "Fix"}}

      assert {:ok, result} = PromptRenderer.render(template, context)
      assert result == "before  after"
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

  describe "render/2 - undefined variables" do
    test "undefined variable renders as empty" do
      template = "Hello {{ undefined_var }}!"
      context = %{"other" => "value"}

      assert {:ok, "Hello !"} = PromptRenderer.render(template, context)
    end

    test "multiple undefined variables render as empty" do
      template = "{{ a }} and {{ b }}"
      context = %{}

      assert {:ok, " and "} = PromptRenderer.render(template, context)
    end

    test "for loop over undefined collection renders nothing" do
      template = "before {% for item in missing %}- {{ item }}\n{% endfor %}after"
      context = %{}

      assert {:ok, "before after"} = PromptRenderer.render(template, context)
    end

    test "if guard on undefined variable suppresses branch" do
      template = "{% if task.missing %}shown{% else %}hidden{% endif %}"
      context = %{"task" => %{}}

      assert {:ok, "hidden"} = PromptRenderer.render(template, context)
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
      template =
        "{% for item in items %}{% if item.active %}{{ item.name }} {% endif %}{% endfor %}"

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

  describe "build_task_context/1" do
    test "returns string-keyed map with id, title, description, level, tags" do
      task = %Sacrum.Repo.Schemas.Task{
        id: "550e8400-e29b-41d4-a716-446655440000",
        title: "Fix login bug",
        description: "Users cannot log in",
        level: "ticket",
        tags: ["urgent", "auth"],
        sections: [],
        code_refs: []
      }

      context = PromptContext.build_task_context(task)

      assert context["id"] == "550e8400-e29b-41d4-a716-446655440000"
      assert context["title"] == "Fix login bug"
      assert context["description"] == "Users cannot log in"
      assert context["level"] == "ticket"
      assert context["tags"] == ["urgent", "auth"]
      assert context["code_refs"] == []
      # Verify all keys are strings
      assert Enum.all?(Map.keys(context), &is_binary/1)
    end

    test "handles nil values in task fields" do
      task = %Sacrum.Repo.Schemas.Task{
        id: "550e8400-e29b-41d4-a716-446655440000",
        title: "Task",
        description: nil,
        level: nil,
        tags: nil,
        sections: [],
        code_refs: []
      }

      context = PromptContext.build_task_context(task)

      assert context["title"] == "Task"
      assert context["description"] == ""
      assert context["level"] == ""
      assert context["tags"] == []
    end

    test "groups sections by type" do
      task = %Sacrum.Repo.Schemas.Task{
        id: "550e8400-e29b-41d4-a716-446655440000",
        title: "Task",
        description: nil,
        level: nil,
        tags: [],
        sections: [
          %Sacrum.Repo.Schemas.TaskSection{
            section_type: "constraint",
            content: "Must work offline"
          },
          %Sacrum.Repo.Schemas.TaskSection{
            section_type: "constraint",
            content: "Must support iOS 14+"
          },
          %Sacrum.Repo.Schemas.TaskSection{
            section_type: "goal",
            content: "Improve performance"
          }
        ],
        code_refs: []
      }

      context = PromptContext.build_task_context(task)

      assert context["constraints"] == ["Must work offline", "Must support iOS 14+"]
      assert context["goals"] == ["Improve performance"]
      # Verify all section keys are strings
      assert Enum.all?(Map.keys(context), &is_binary/1)
    end

    test "includes code refs with path, line_start, line_end, name, description" do
      task = %Sacrum.Repo.Schemas.Task{
        id: "550e8400-e29b-41d4-a716-446655440000",
        title: "Task",
        description: nil,
        level: nil,
        tags: [],
        sections: [],
        code_refs: [
          %Sacrum.Repo.Schemas.CodeRef{
            path: "lib/my_app/auth.ex",
            line_start: 10,
            line_end: 25,
            name: "authenticate",
            description: "Auth function"
          },
          %Sacrum.Repo.Schemas.CodeRef{
            path: "lib/my_app/auth.ex",
            line_start: 50,
            line_end: 60,
            name: nil,
            description: nil
          }
        ]
      }

      context = PromptContext.build_task_context(task)

      assert length(context["code_refs"]) == 2
      ref1 = Enum.at(context["code_refs"], 0)
      assert ref1["path"] == "lib/my_app/auth.ex"
      assert ref1["line_start"] == 10
      assert ref1["line_end"] == 25
      assert ref1["name"] == "authenticate"
      assert ref1["description"] == "Auth function"

      ref2 = Enum.at(context["code_refs"], 1)
      assert ref2["path"] == "lib/my_app/auth.ex"
      assert ref2["line_start"] == 50
      # Verify all nested keys are strings
      assert Enum.all?(Map.keys(ref1), &is_binary/1)
    end

    test "normalizes section types to plural forms" do
      task = %Sacrum.Repo.Schemas.Task{
        id: "550e8400-e29b-41d4-a716-446655440000",
        title: "Task",
        description: nil,
        level: nil,
        tags: [],
        sections: [
          %Sacrum.Repo.Schemas.TaskSection{
            section_type: "testing_criterion",
            content: "Must handle nulls"
          },
          %Sacrum.Repo.Schemas.TaskSection{
            section_type: "anti_pattern",
            content: "Avoid loops"
          }
        ],
        code_refs: []
      }

      context = PromptContext.build_task_context(task)

      assert context["testing_criteria"] == ["Must handle nulls"]
      assert context["anti_patterns"] == ["Avoid loops"]
    end
  end

  describe "build_execution_context/1" do
    test "extracts previous output and run count" do
      execution_data = %{
        previous: %{output: "Some output text"},
        run_count: 2,
        completed_count: 1,
        failed_count: 1,
        duration_ms: 1500
      }

      context = PromptContext.build_execution_context(execution_data)

      assert context["previous_output"] == "Some output text"
      assert context["run_count"] == 2
      assert context["completed_count"] == 1
      assert context["failed_count"] == 1
      assert context["duration_ms"] == 1500
      assert Enum.all?(Map.keys(context), &is_binary/1)
    end

    test "handles missing previous output" do
      execution_data = %{
        run_count: 0
      }

      context = PromptContext.build_execution_context(execution_data)

      assert context["previous_output"] == ""
      assert context["run_count"] == 0
      assert context["completed_count"] == 0
      assert context["failed_count"] == 0
    end

    test "builds history list from executions" do
      execution_data = %{
        previous: %{output: "Output"},
        run_count: 1,
        history: [
          %{step_name: "draft", status: "completed", output: "First output"},
          %{step_name: "review", status: "pending", duration_ms: 2000}
        ]
      }

      context = PromptContext.build_execution_context(execution_data)

      assert length(context["history"]) == 2
      history_1 = Enum.at(context["history"], 0)
      assert history_1["step_name"] == "draft"
      assert history_1["status"] == "completed"
      assert history_1["output"] == "First output"

      history_2 = Enum.at(context["history"], 1)
      assert history_2["step_name"] == "review"
      assert history_2["status"] == "pending"
      assert history_2["duration_ms"] == 2000
    end

    test "handles nil execution_data gracefully" do
      context = PromptContext.build_execution_context(nil)
      assert context == %{}
    end

    test "excludes nil values from context" do
      execution_data = %{
        previous: %{output: "Some output"},
        retry_count: 0
      }

      context = PromptContext.build_execution_context(execution_data)

      # duration_ms should not be present if nil
      assert !Map.has_key?(context, "duration_ms")
      assert context["previous_output"] == "Some output"
    end
  end

  describe "build_workflow_context/2" do
    test "extracts workflow name, current step, and step count" do
      workflow = %Sacrum.Repo.Schemas.Workflow{
        id: "wf-id",
        name: "Task Workflow",
        workflow_steps: [
          %Sacrum.Repo.Schemas.WorkflowStep{name: "draft"},
          %Sacrum.Repo.Schemas.WorkflowStep{name: "review"},
          %Sacrum.Repo.Schemas.WorkflowStep{name: "done"}
        ]
      }

      workflow_step = %Sacrum.Repo.Schemas.WorkflowStep{
        id: "step-id",
        name: "review",
        goal: "Review the implementation",
        workflow: workflow
      }

      task = %Sacrum.Repo.Schemas.Task{}

      context = PromptContext.build_workflow_context(workflow_step, task)

      assert context["name"] == "Task Workflow"
      assert context["current_step"] == "review"
      assert context["current_step_goal"] == "Review the implementation"
      assert context["step_count"] == 3
      # Verify all keys are strings
      assert Enum.all?(Map.keys(context), &is_binary/1)
    end

    test "uses task.workflow if step.workflow is nil" do
      task = %Sacrum.Repo.Schemas.Task{
        workflow: %Sacrum.Repo.Schemas.Workflow{
          id: "wf-id",
          name: "Task Workflow",
          workflow_steps: [
            %Sacrum.Repo.Schemas.WorkflowStep{name: "step1"},
            %Sacrum.Repo.Schemas.WorkflowStep{name: "step2"}
          ]
        }
      }

      workflow_step = %Sacrum.Repo.Schemas.WorkflowStep{
        id: "step-id",
        name: "step1",
        goal: "First step",
        workflow: nil
      }

      context = PromptContext.build_workflow_context(workflow_step, task)

      assert context["name"] == "Task Workflow"
      assert context["step_count"] == 2
    end

    test "returns empty map when workflow_step is nil" do
      task = %Sacrum.Repo.Schemas.Task{workflow: nil}
      context = PromptContext.build_workflow_context(nil, task)

      assert context == %{}
    end

    test "returns empty map when no workflow is available" do
      workflow_step = %Sacrum.Repo.Schemas.WorkflowStep{
        id: "step-id",
        name: "review",
        goal: "Review",
        workflow: nil
      }

      task = %Sacrum.Repo.Schemas.Task{workflow: nil}

      context = PromptContext.build_workflow_context(workflow_step, task)

      assert context == %{}
    end

    test "handles nil step name and goal" do
      workflow = %Sacrum.Repo.Schemas.Workflow{
        id: "wf-id",
        name: "Workflow",
        workflow_steps: []
      }

      workflow_step = %Sacrum.Repo.Schemas.WorkflowStep{
        id: "step-id",
        name: nil,
        goal: nil,
        workflow: workflow
      }

      task = %Sacrum.Repo.Schemas.Task{}

      context = PromptContext.build_workflow_context(workflow_step, task)

      assert context["current_step"] == ""
      assert context["current_step_goal"] == ""
    end
  end

  describe "build_context/3" do
    test "merges task, execution, and workflow contexts into single map" do
      task = %Sacrum.Repo.Schemas.Task{
        id: "task-id",
        title: "Test Task",
        description: "A test task",
        level: "ticket",
        tags: ["test"],
        sections: [],
        code_refs: [],
        workflow: %Sacrum.Repo.Schemas.Workflow{
          name: "Default",
          workflow_steps: []
        }
      }

      execution_data = %{
        previous: %{output: "Previous output"},
        run_count: 1,
        duration_ms: 500
      }

      workflow_step = %Sacrum.Repo.Schemas.WorkflowStep{
        name: "draft",
        goal: "Initial draft",
        workflow: nil
      }

      context = PromptContext.build_context(task, execution_data, workflow_step)

      # Verify top-level keys
      assert Map.has_key?(context, "task")
      assert Map.has_key?(context, "execution")
      assert Map.has_key?(context, "workflow")

      # Verify task context
      assert context["task"]["title"] == "Test Task"
      assert context["task"]["level"] == "ticket"

      # Verify execution context
      assert context["execution"]["previous_output"] == "Previous output"
      assert context["execution"]["run_count"] == 1

      # Verify workflow context
      assert context["workflow"]["name"] == "Default"
      assert context["workflow"]["current_step"] == "draft"

      # Verify all keys at every level are strings
      assert Enum.all?(Map.keys(context), &is_binary/1)
      assert Enum.all?(Map.keys(context["task"]), &is_binary/1)
      assert Enum.all?(Map.keys(context["execution"]), &is_binary/1)
      assert Enum.all?(Map.keys(context["workflow"]), &is_binary/1)
    end

    test "handles nil workflow_step gracefully" do
      task = %Sacrum.Repo.Schemas.Task{
        id: "task-id",
        title: "Task",
        description: nil,
        level: nil,
        tags: [],
        sections: [],
        code_refs: []
      }

      execution_data = %{run_count: 0}

      context = PromptContext.build_context(task, execution_data, nil)

      assert context["task"]["title"] == "Task"
      assert context["execution"]["run_count"] == 0
      assert context["workflow"] == %{}
    end

    test "all nested keys are strings for Liquid compatibility" do
      task = %Sacrum.Repo.Schemas.Task{
        id: "task-id",
        title: "Task",
        description: nil,
        level: nil,
        tags: [],
        sections: [
          %Sacrum.Repo.Schemas.TaskSection{section_type: "goal", content: "Test goal"}
        ],
        code_refs: [
          %Sacrum.Repo.Schemas.CodeRef{
            path: "test.ex",
            line_start: 1,
            line_end: 5,
            name: "test_func",
            description: "Test"
          }
        ]
      }

      execution_data = %{
        previous: %{output: "output"},
        history: [%{step_name: "draft", status: "completed"}]
      }

      workflow_step = %Sacrum.Repo.Schemas.WorkflowStep{
        name: "draft",
        goal: "Draft",
        workflow: %Sacrum.Repo.Schemas.Workflow{
          name: "WF",
          workflow_steps: [%{}]
        }
      }

      context = PromptContext.build_context(task, execution_data, workflow_step)

      # Recursively check all keys are strings
      assert all_keys_are_strings(context)
    end
  end

  defp all_keys_are_strings(map) when is_map(map) do
    Enum.all?(map, fn {key, value} ->
      is_binary(key) && all_keys_are_strings(value)
    end)
  end

  defp all_keys_are_strings(list) when is_list(list) do
    Enum.all?(list, &all_keys_are_strings/1)
  end

  defp all_keys_are_strings(_), do: true
end
