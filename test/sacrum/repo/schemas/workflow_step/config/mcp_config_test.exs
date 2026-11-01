defmodule Sacrum.Repo.Schemas.WorkflowStep.Config.McpConfigTest do
  use ExUnit.Case, async: true

  alias Sacrum.Repo.Schemas.WorkflowStep.Config.McpConfig

  @secret "sk-live-do-not-echo"

  @inline %{
    "mcpServers" => %{
      "gate" => %{
        "command" => "gate-mcp",
        "args" => ["--stdio"],
        "env" => %{"GATE_TOKEN" => "${GATE_TOKEN}"}
      },
      "docs" => %{
        "type" => "http",
        "url" => "https://docs.example.com/mcp",
        "headers" => %{"Authorization" => "Bearer ${DOCS_TOKEN}"}
      }
    }
  }

  defp mcp(entries, extra \\ %{}), do: Map.merge(%{"mcp_config" => entries}, extra)

  defp assert_invalid(agent_config, path, message) do
    assert {:error, %{code: :mcp_config_invalid, path: ^path, message: actual}} =
             McpConfig.validate(agent_config)

    assert actual =~ message
    refute inspect(McpConfig.validate(agent_config)) =~ @secret
  end

  describe "valid configs" do
    test "agent configs without MCP settings are untouched" do
      for agent_config <- [
            nil,
            %{},
            %{"model" => "opus", "allowed_tools" => ["mcp__gate__lookup"], "tools" => []}
          ] do
        assert :ok = McpConfig.validate(agent_config)
      end
    end

    test "accepts inline configs, daemon paths, mixes and strict mode" do
      for agent_config <- [
            mcp([]),
            mcp([@inline]),
            mcp(["/etc/vertebrae/mcp.json"]),
            mcp(["~/.config/vertebrae/mcp.json", @inline]),
            mcp([@inline], %{
              "strict_mcp_config" => true,
              "allowed_tools" => ["mcp__gate__lookup"]
            }),
            %{"strict_mcp_config" => true},
            %{"strict_mcp_config" => false}
          ] do
        assert :ok = McpConfig.validate(agent_config), inspect(agent_config)
      end
    end
  end

  describe "invalid configs" do
    test "mcp_config must be a list and strict_mcp_config a boolean" do
      for value <- [@inline, "/etc/mcp.json", nil] do
        assert_invalid(%{"mcp_config" => value}, "$.agent_config.mcp_config", "must be a list")
      end

      for value <- ["true", 1, nil] do
        assert_invalid(
          %{"strict_mcp_config" => value},
          "$.agent_config.strict_mcp_config",
          "must be true or false"
        )
      end
    end

    test "entries must be objects or paths" do
      assert_invalid(mcp([42]), "$.agent_config.mcp_config[0]", "inline MCP config object")

      assert_invalid(
        mcp([~s({"mcpServers":{"gate":{"command":"x"}}})]),
        "$.agent_config.mcp_config[0]",
        "must be an object, not a string"
      )
    end

    test "daemon paths must be absolute and explicit" do
      for {path, message} <- [
            {".mcp.json", "absolute daemon-local path"},
            {"/etc/../root/mcp.json", ".. segments"},
            {"/srv/{{ task.title }}.json", "not templated"}
          ] do
        assert_invalid(mcp(["/ok.json", path]), "$.agent_config.mcp_config[1]", message)
      end
    end

    test "inline JSON must be a well-formed MCP config" do
      for {entry, path, message} <- [
            {%{}, "mcpServers", "is required"},
            {%{"mcpServers" => %{}}, "mcpServers", "at least one server"},
            {%{"mcpServers" => %{"gate" => %{"command" => "x"}}, "extra" => 1}, "extra",
             "not supported"},
            {%{"mcpServers" => %{"bad name" => %{"command" => "x"}}}, "mcpServers",
             "server names may only contain"},
            {%{"mcpServers" => %{"gate" => %{}}}, "mcpServers.gate", "command or a url"},
            {%{"mcpServers" => %{"gate" => %{"command" => "a", "url" => "b"}}}, "mcpServers.gate",
             "not both"},
            {%{"mcpServers" => %{"gate" => %{"command" => "{{ task.title }}"}}},
             "mcpServers.gate.command", "not templated"}
          ] do
        assert_invalid(mcp([entry]), "$.agent_config.mcp_config[0].#{path}", message)
      end
    end

    test "inline credentials must be runtime references and are never echoed" do
      for {field, value, message} <- [
            {"env", @secret, "must reference a daemon environment variable"},
            {"env", "${GATE_TOKEN:-#{@secret}}", "defaults are not supported"},
            {"headers", "Bearer #{@secret}", "must reference a daemon environment variable"}
          ] do
        entry = %{
          "mcpServers" => %{"gate" => %{"command" => "gate-mcp", field => %{"TOKEN" => value}}}
        }

        assert_invalid(
          mcp([entry]),
          "$.agent_config.mcp_config[0].mcpServers.gate.#{field}.TOKEN",
          message
        )
      end
    end
  end
end
