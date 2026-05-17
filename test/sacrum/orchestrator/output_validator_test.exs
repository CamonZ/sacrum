defmodule Sacrum.Orchestrator.OutputValidatorTest do
  use Sacrum.DataCase, async: true

  alias Sacrum.Orchestrator.OutputValidator

  describe "validate_output/2" do
    test "returns ok when schema is nil" do
      assert :ok = OutputValidator.validate_output(%{"any" => "data"}, nil)
    end

    test "validates output against valid JSON Schema" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"},
          "age" => %{"type" => "integer"}
        },
        "required" => ["name"]
      }

      valid_output = %{"name" => "John", "age" => 30}
      assert :ok = OutputValidator.validate_output(valid_output, schema)
    end

    test "rejects output that doesn't match schema" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "name" => %{"type" => "string"}
        },
        "required" => ["name"]
      }

      invalid_output = %{"age" => 30}

      assert {:error, {:validation_failed, errors}} =
               OutputValidator.validate_output(invalid_output, schema)

      assert is_list(errors)
      assert length(errors) > 0
    end

    test "rejects invalid schema type" do
      invalid_output = %{"test" => "data"}

      assert {:error, {:invalid_schema_type, _}} =
               OutputValidator.validate_output(invalid_output, "not a map")
    end

    test "validates required fields" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "required_field" => %{"type" => "string"}
        },
        "required" => ["required_field"]
      }

      output_missing_required = %{"other" => "value"}

      assert {:error, {:validation_failed, _}} =
               OutputValidator.validate_output(output_missing_required, schema)
    end

    test "validates nested objects" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "user" => %{
            "type" => "object",
            "properties" => %{
              "name" => %{"type" => "string"}
            },
            "required" => ["name"]
          }
        },
        "required" => ["user"]
      }

      valid_nested = %{"user" => %{"name" => "Alice"}}
      assert :ok = OutputValidator.validate_output(valid_nested, schema)

      invalid_nested = %{"user" => %{"age" => 25}}

      assert {:error, {:validation_failed, _}} =
               OutputValidator.validate_output(invalid_nested, schema)
    end

    test "validates arrays" do
      schema = %{
        "type" => "object",
        "properties" => %{
          "items" => %{
            "type" => "array",
            "items" => %{"type" => "string"}
          }
        }
      }

      valid_array = %{"items" => ["a", "b", "c"]}
      assert :ok = OutputValidator.validate_output(valid_array, schema)

      invalid_array = %{"items" => ["a", 2, "c"]}

      assert {:error, {:validation_failed, _}} =
               OutputValidator.validate_output(invalid_array, schema)
    end
  end

  describe "validate_routing_contract/1" do
    test "accepts valid routing contract output" do
      output = %{
        "transition_to" => Ecto.UUID.generate(),
        "transition_type" => "intra_workflow"
      }

      assert :ok = OutputValidator.validate_routing_contract(output)
    end

    test "accepts inter_workflow transition type" do
      output = %{
        "transition_to" => Ecto.UUID.generate(),
        "transition_type" => "inter_workflow"
      }

      assert :ok = OutputValidator.validate_routing_contract(output)
    end

    test "rejects missing transition_to" do
      output = %{"transition_type" => "intra_workflow"}

      assert {:error, {:validation_failed, _}} =
               OutputValidator.validate_routing_contract(output)
    end

    test "rejects missing transition_type" do
      output = %{"transition_to" => Ecto.UUID.generate()}

      assert {:error, {:validation_failed, _}} =
               OutputValidator.validate_routing_contract(output)
    end

    test "rejects invalid transition_type" do
      output = %{
        "transition_to" => Ecto.UUID.generate(),
        "transition_type" => "invalid_type"
      }

      assert {:error, {:validation_failed, _}} =
               OutputValidator.validate_routing_contract(output)
    end

    test "rejects unexpected keys" do
      output = %{
        "transition_to" => Ecto.UUID.generate(),
        "transition_type" => "intra_workflow",
        "extra_field" => "unexpected"
      }

      assert {:error, {:validation_failed, _}} =
               OutputValidator.validate_routing_contract(output)
    end

    test "accepts handoff matching a custom strict route schema" do
      schema =
        Sacrum.Repo.Schemas.WorkflowStep.routing_contract_schema(%{
          "type" => "object",
          "properties" => %{
            "summary" => %{"type" => "string"},
            "priority" => %{"type" => "string"}
          },
          "required" => ["summary", "priority"],
          "additionalProperties" => false
        })

      output = %{
        "transition_to" => Ecto.UUID.generate(),
        "transition_type" => "intra_workflow",
        "handoff" => %{"summary" => "ready", "priority" => "high"}
      }

      assert :ok = OutputValidator.validate_routing_contract(output, schema)
    end

    test "rejects handoff that does not match a custom strict route schema" do
      schema =
        Sacrum.Repo.Schemas.WorkflowStep.routing_contract_schema(%{
          "type" => "object",
          "properties" => %{"summary" => %{"type" => "string"}},
          "required" => ["summary"],
          "additionalProperties" => false
        })

      output = %{
        "transition_to" => Ecto.UUID.generate(),
        "transition_type" => "intra_workflow",
        "handoff" => %{"summary" => "ready", "extra" => "nope"}
      }

      assert {:error, {:validation_failed, _}} =
               OutputValidator.validate_routing_contract(output, schema)
    end

    test "rejects non-map output" do
      assert {:error, {:invalid_output_type, _}} =
               OutputValidator.validate_routing_contract("not a map")
    end
  end
end
