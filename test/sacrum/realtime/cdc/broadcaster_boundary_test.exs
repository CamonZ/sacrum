defmodule Sacrum.Realtime.Cdc.BroadcasterBoundaryTest do
  use ExUnit.Case, async: true

  alias Sacrum.Realtime.CommandBroadcaster
  alias Sacrum.Realtime.ProjectChannelCdcContract

  @guarded_roots [
    "lib/sacrum",
    "lib/sacrum_web/graphql"
  ]

  @allowed_project_channel_callers [
    "lib/sacrum/realtime/cdc/projector.ex",
    "lib/sacrum/realtime/command_broadcaster.ex"
  ]

  test "regular-client state events are not emitted directly from persistence paths" do
    regular_client_broadcasts = regular_client_broadcast_functions()

    violations =
      @guarded_roots
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex")))
      |> Enum.flat_map(&forbidden_broadcast_calls(&1, regular_client_broadcasts))
      |> Enum.sort()

    assert violations == []
  end

  test "the imperative broadcaster is narrowed to daemon commands" do
    exported_functions =
      CommandBroadcaster.__info__(:functions)
      |> Keyword.keys()
      |> Enum.sort()

    assert exported_functions == [:broadcast_cancel_step, :broadcast_run_step]
    refute File.exists?("lib/sacrum/repo/broadcaster.ex")
  end

  defp regular_client_broadcast_functions do
    ProjectChannelCdcContract.regular_event_names()
    |> Enum.map(&String.to_atom("broadcast_" <> &1))
    |> MapSet.new()
  end

  defp forbidden_broadcast_calls(file, regular_client_broadcasts) do
    ast =
      file
      |> File.read!()
      |> Code.string_to_quoted!(file: file)

    {_ast, {_aliases, violations}} =
      Macro.prewalk(ast, {%{}, []}, fn node, {aliases, violations} ->
        aliases = aliases_for_node(node, aliases)

        node_violations =
          node_violations(file, node, regular_client_broadcasts, aliases)

        {node, {aliases, node_violations ++ violations}}
      end)

    violations
  end

  defp aliases_for_node(
         {:alias, _meta, [{:__aliases__, _alias_meta, segments}], alias_opts},
         aliases
       ) do
    alias_name = alias_name(segments, alias_opts)
    Map.put(aliases, alias_name, segments)
  end

  defp aliases_for_node(_node, aliases), do: aliases

  defp node_violations(
         file,
         {{:., meta, [remote, function]}, _call_meta, _args},
         regular_client_broadcasts,
         aliases
       )
       when is_atom(function) do
    remote_segments = remote_segments(remote, aliases)

    cond do
      old_repo_broadcaster?(remote_segments) ->
        [violation(file, meta, remote_segments, function)]

      project_channel_remote?(remote_segments) and function in regular_client_broadcasts and
          file not in @allowed_project_channel_callers ->
        [violation(file, meta, remote_segments, function)]

      true ->
        []
    end
  end

  defp node_violations(
         file,
         {:alias, meta, [{:__aliases__, _alias_meta, segments}], alias_opts},
         _regular,
         _aliases
       ) do
    if old_repo_broadcaster?(segments) do
      [violation(file, meta, segments, :alias)]
    else
      aliased_name = alias_name(segments, alias_opts)

      if aliased_name != :ProjectChannel and segments == [:SacrumWeb, :ProjectChannel] do
        [violation(file, meta, segments, :alias)]
      else
        []
      end
    end
  end

  defp node_violations(_file, _node, _regular_client_broadcasts, _aliases), do: []

  defp alias_name(segments, alias_opts) do
    case Keyword.get(alias_opts, :as) do
      {:__aliases__, _meta, [name]} -> name
      name when is_atom(name) -> name
      nil -> List.last(segments)
    end
  end

  defp remote_segments({:__aliases__, _meta, [alias_name]}, aliases) do
    if Map.has_key?(aliases, alias_name) do
      Map.fetch!(aliases, alias_name)
    else
      [alias_name]
    end
  end

  defp remote_segments({:__aliases__, _meta, segments}, _aliases), do: segments

  defp remote_segments(remote, aliases) when is_atom(remote) do
    Map.get(aliases, remote, [remote])
  end

  defp remote_segments(_remote, _aliases), do: []

  defp old_repo_broadcaster?(segments) do
    segments == [:Sacrum, :Repo, :Broadcaster] or segments == [:Broadcaster]
  end

  defp project_channel_remote?(segments), do: List.last(segments) == :ProjectChannel

  defp violation(file, meta, segments, function) do
    line = Keyword.get(meta, :line, 1)
    remote = Enum.map_join(segments, ".", &Atom.to_string/1)
    "#{file}:#{line} #{remote}.#{function}"
  end
end
