defmodule Sacrum.Repo.Schemas.WorkflowStep.Config.McpConfig do
  @moduledoc """
  Validates the MCP settings of an `llm_inference` step's `agent_config`:
  `mcp_config`, the MCP configuration the daemon feeds the agent, and
  `strict_mcp_config`, which asks the daemon to ignore ambient MCP config.

  Each `mcp_config` entry is either inline MCP JSON (`{"mcpServers": {...}}`)
  or an absolute path on the daemon's machine. Sacrum checks the shape and
  forwards both keys verbatim in `run_step`; reading files, materializing
  inline JSON, resolving `${VAR}` credentials and enforcing tool restrictions
  (`allowed_tools`/`disallowed_tools`) belong to the daemon. See
  `docs/llm-mcp-config.md`.

  Error messages name the offending path but never the offending value, so a
  credential pasted into the config is not echoed in errors or logs.
  """

  @type error :: %{code: :mcp_config_invalid, path: String.t(), message: String.t()}

  @root "$.agent_config.mcp_config"
  @server_name ~r/\A[A-Za-z0-9_-]+\z/
  @env_reference ~r/\$\{[A-Za-z_][A-Za-z0-9_]*\}/
  @any_reference ~r/\$\{[^}]*\}/

  @doc """
  Validates `mcp_config` and `strict_mcp_config` in `agent_config`.

  `agent_config` is JSON from GraphQL, bundle import or the database, so its
  keys are strings; only string keys are recognized.
  """
  @spec validate(term()) :: :ok | {:error, error()}
  def validate(agent_config) when is_map(agent_config) do
    with :ok <- validate_strict(Map.fetch(agent_config, "strict_mcp_config")) do
      validate_entries(Map.fetch(agent_config, "mcp_config"))
    end
  end

  def validate(_agent_config), do: :ok

  defp validate_strict(:error), do: :ok
  defp validate_strict({:ok, value}) when is_boolean(value), do: :ok

  defp validate_strict({:ok, _value}),
    do: error("$.agent_config.strict_mcp_config", "must be true or false")

  defp validate_entries(:error), do: :ok

  defp validate_entries({:ok, entries}) when is_list(entries) do
    entries
    |> Enum.with_index()
    |> each(fn {entry, index} -> validate_entry(entry, "#{@root}[#{index}]") end)
  end

  defp validate_entries({:ok, _entries}),
    do: error(@root, "must be a list of inline MCP configs or daemon-local paths")

  defp validate_entry(entry, path) when is_binary(entry) do
    cond do
      String.starts_with?(String.trim_leading(entry), "{") ->
        error(path, "inline MCP JSON must be an object, not a string")

      String.contains?(entry, "{{") or String.contains?(entry, "}}") ->
        error(path, "agent_config is not templated; {{ }} interpolations are not supported")

      not (String.starts_with?(entry, "/") or String.starts_with?(entry, "~/")) ->
        error(path, "must be an absolute daemon-local path (starting with / or ~/)")

      String.contains?(entry, "\0") ->
        error(path, "must not contain NUL bytes")

      ".." in Path.split(entry) ->
        error(path, "must not contain .. segments")

      true ->
        :ok
    end
  end

  defp validate_entry(entry, path) when is_map(entry) do
    with :ok <- string_keys(entry, path),
         :ok <- no_templates(entry, path),
         :ok <- only_keys(entry, ["mcpServers"], path) do
      if Map.has_key?(entry, "mcpServers"),
        do: validate_servers(entry["mcpServers"], "#{path}.mcpServers"),
        else: error("#{path}.mcpServers", "is required")
    end
  end

  defp validate_entry(_entry, path),
    do: error(path, "must be an inline MCP config object or a daemon-local path")

  defp validate_servers(servers, path) when is_map(servers) and map_size(servers) > 0 do
    servers
    |> Enum.sort_by(fn {name, _} -> name end)
    |> each(fn {name, server} ->
      with :ok <- server_name(name, path) do
        validate_server(server, path_for_key(path, name))
      end
    end)
  end

  defp validate_servers(_servers, path),
    do: error(path, "must be an object declaring at least one server")

  defp validate_server(server, path) when is_map(server) do
    with :ok <- one_transport(server, path),
         :ok <- runtime_references(Map.get(server, "env"), "#{path}.env") do
      runtime_references(Map.get(server, "headers"), "#{path}.headers")
    end
  end

  defp validate_server(_server, path), do: error(path, "must be an object")

  defp one_transport(server, path) do
    case {Map.get(server, "command"), Map.get(server, "url")} do
      {command, nil} when is_binary(command) and command != "" ->
        :ok

      {nil, url} when is_binary(url) and url != "" ->
        :ok

      {nil, nil} ->
        error(path, "must declare a command or a url")

      {command, url} when not is_nil(command) and not is_nil(url) ->
        error(path, "must declare either a command or a url, not both")

      _invalid ->
        error(path, "command or url must be a non-empty string")
    end
  end

  # Credentials are referenced, never stored: every env and header value must
  # name a daemon-side environment variable such as `${API_TOKEN}`.
  defp runtime_references(nil, _path), do: :ok

  defp runtime_references(values, path) when is_map(values) do
    values
    |> Enum.sort_by(fn {key, _} -> key end)
    |> each(fn {key, value} -> runtime_reference(value, path_for_key(path, key)) end)
  end

  defp runtime_references(_values, path), do: error(path, "must be an object of strings")

  defp runtime_reference(value, path) when is_binary(value) do
    references = Regex.scan(@any_reference, value)
    env_references = Regex.scan(@env_reference, value)

    cond do
      length(references) != length(env_references) ->
        error(path, "references must have the form ${NAME}; defaults are not supported")

      env_references == [] ->
        error(
          path,
          "must reference a daemon environment variable such as ${API_TOKEN}; " <>
            "literal values are not stored in workflow config"
        )

      true ->
        :ok
    end
  end

  defp runtime_reference(_value, path), do: error(path, "must be a string")

  defp server_name(name, path) do
    if is_binary(name) and Regex.match?(@server_name, name),
      do: :ok,
      else: error(path, "server names may only contain letters, digits, _ and -")
  end

  defp only_keys(map, allowed, path) do
    case map |> Map.keys() |> Enum.reject(&(&1 in allowed)) |> Enum.sort() do
      [] -> :ok
      [key | _] -> error(path_for_key(path, key), "is not supported")
    end
  end

  defp string_keys(value, path) when is_map(value) do
    if Enum.all?(Map.keys(value), &is_binary/1) do
      value |> Map.values() |> each(&string_keys(&1, path))
    else
      error(path, "must use string keys")
    end
  end

  defp string_keys(value, path) when is_list(value), do: each(value, &string_keys(&1, path))
  defp string_keys(_value, _path), do: :ok

  # agent_config is forwarded verbatim; a `{{ }}` would reach the daemon as
  # literal text, so it is rejected rather than silently left unrendered.
  defp no_templates(value, path) when is_map(value) do
    value
    |> Enum.sort_by(fn {key, _} -> key end)
    |> each(fn {key, nested} -> no_templates(nested, path_for_key(path, key)) end)
  end

  defp no_templates(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> each(fn {nested, index} -> no_templates(nested, "#{path}[#{index}]") end)
  end

  defp no_templates(value, path) when is_binary(value) do
    if String.contains?(value, "{{") or String.contains?(value, "}}"),
      do: error(path, "agent_config is not templated; {{ }} interpolations are not supported"),
      else: :ok
  end

  defp no_templates(_value, _path), do: :ok

  defp each(enumerable, fun) do
    Enum.reduce_while(enumerable, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp path_for_key(path, key) when is_binary(key) do
    if Regex.match?(~r/\A[A-Za-z_][A-Za-z0-9_]*\z/, key),
      do: "#{path}.#{key}",
      else: "#{path}[#{inspect(key)}]"
  end

  defp path_for_key(path, _key), do: path

  defp error(path, message),
    do: {:error, %{code: :mcp_config_invalid, path: path, message: message}}
end
