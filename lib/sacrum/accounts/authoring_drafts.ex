defmodule Sacrum.Accounts.AuthoringDrafts do
  @moduledoc """
  Domain service for state-machine authored draft artifacts.
  """

  import Ecto.Query

  alias Sacrum.Accounts.Artifacts
  alias Sacrum.Accounts.ChatSessions
  alias Sacrum.Repo
  alias Sacrum.Repo.ArtifactLinks
  alias Sacrum.Repo.Artifacts, as: ArtifactsRepo
  alias Sacrum.Repo.Schemas.{Artifact, ArtifactLink, ChatSession}

  @artifact_type "authoring_draft"
  @artifact_state "draft"
  @visibility "public"
  @redaction_state "not_needed"
  @subject_type "chat_session"
  @relationship_kind "produced_by"
  @append_fields ~w(
    assumptions open_questions proposed_approach candidate_work_units apply_targets revision_notes
  )
  @replace_fields ~w(
    state_machine_id state_machine_entrypoint current_state revision source_chat
    knowns unknowns initial_state template trigger
    workflows steps prompts output_schema transitions required_sections
    required_section_templates validation_expectations
  )

  @spec upsert_for_chat_session(String.t(), String.t(), String.t(), map()) ::
          {:ok, %{artifact: Artifact.t(), link: ArtifactLink.t()}}
          | {:error, Ecto.Changeset.t()}
          | {:error,
             :not_found
             | :artifact_scope_mismatch
             | :subject_scope_mismatch
             | :missing_state_machine_id}
  def upsert_for_chat_session(user_id, project_id, chat_session_id, patch)
      when is_binary(user_id) and is_binary(project_id) and is_binary(chat_session_id) and
             is_map(patch) do
    normalized_patch = stringify_keys(patch)

    with {:ok, state_machine_id} <- fetch_state_machine_id(normalized_patch),
         {:ok, chat_session} <- ChatSessions.get_session(user_id, project_id, chat_session_id) do
      upsert_for_chat_session(chat_session, normalized_patch, state_machine_id)
    end
  end

  @spec upsert_for_chat_session(ChatSession.t(), map()) ::
          {:ok, %{artifact: Artifact.t(), link: ArtifactLink.t()}}
          | {:error, Ecto.Changeset.t()}
          | {:error, :missing_state_machine_id}
  def upsert_for_chat_session(%ChatSession{} = chat_session, patch) when is_map(patch) do
    normalized_patch = stringify_keys(patch)

    with {:ok, state_machine_id} <- fetch_state_machine_id(normalized_patch) do
      upsert_for_chat_session(chat_session, normalized_patch, state_machine_id)
    end
  end

  @spec get_for_chat_session(ChatSession.t(), String.t()) ::
          {:ok, %{artifact: Artifact.t(), link: ArtifactLink.t()}} | {:error, :not_found}
  def get_for_chat_session(%ChatSession{} = chat_session, state_machine_id)
      when is_binary(state_machine_id) do
    case existing_draft(chat_session, state_machine_id) do
      nil -> {:error, :not_found}
      {artifact, link} -> {:ok, %{artifact: artifact, link: link}}
    end
  end

  defp upsert_for_chat_session(%ChatSession{} = chat_session, normalized_patch, state_machine_id) do
    Repo.transaction(fn ->
      chat_session
      |> upsert_draft(state_machine_id, normalized_patch)
      |> persist_result()
    end)
  end

  defp upsert_draft(%ChatSession{} = chat_session, state_machine_id, patch) do
    case existing_draft(chat_session, state_machine_id) do
      nil ->
        create_draft(chat_session, resolve_patch_revision(patch, nil))

      {artifact, link} ->
        if already_applied?(artifact, patch) do
          {:ok, %{artifact: artifact, link: link}}
        else
          update_draft(artifact, link, resolve_patch_revision(patch, artifact))
        end
    end
  end

  defp persist_result({:ok, result}), do: result
  defp persist_result({:error, reason}), do: Repo.rollback(reason)

  defp fetch_state_machine_id(patch) do
    case Map.fetch(patch, "state_machine_id") do
      {:ok, state_machine_id} when is_binary(state_machine_id) -> {:ok, state_machine_id}
      _ -> {:error, :missing_state_machine_id}
    end
  end

  defp resolve_patch_revision(%{"revision" => :next} = patch, artifact) do
    revision = next_revision(artifact)

    patch
    |> Map.put("revision", revision)
    |> put_source_chat_turn(revision)
  end

  defp resolve_patch_revision(patch, _artifact), do: patch

  defp next_revision(%Artifact{data: %{"revision" => revision}}) when is_integer(revision) do
    revision + 1
  end

  defp next_revision(_artifact_or_nil), do: 1

  defp put_source_chat_turn(%{"source_chat" => source_chat} = patch, revision)
       when is_integer(revision) and is_map(source_chat) do
    put_in(patch, ["source_chat", "turn_index"], revision)
  end

  defp put_source_chat_turn(patch, _revision), do: patch

  defp create_draft(%ChatSession{} = chat_session, patch) do
    Artifacts.create_and_link(
      chat_session.user_id,
      chat_session.project_id,
      %{
        artifact_type: @artifact_type,
        artifact_state: @artifact_state,
        visibility: @visibility,
        redaction_state: @redaction_state,
        title: "#{patch["state_machine_id"]} authoring draft",
        data: draft_data(%{}, patch)
      },
      link_attrs(chat_session, patch)
    )
  end

  defp link_attrs(%ChatSession{} = chat_session, patch) do
    chat_session
    |> ChatSessions.artifact_provenance_link_attrs(
      relationship_kind: @relationship_kind,
      source_message_id: source_message_id(patch)
    )
    |> Map.update!(:metadata, fn metadata ->
      metadata
      |> Map.merge(link_metadata(patch))
      |> stringify_keys()
    end)
  end

  defp source_message_id(%{"source_chat" => %{"source_message_id" => source_message_id}}) do
    source_message_id
  end

  defp source_message_id(_patch), do: nil

  defp already_applied?(
         %Artifact{
           data: %{
             "current_state" => current_state,
             "source_chat" => %{"source_message_id" => source_message_id}
           }
         },
         patch
       )
       when is_binary(source_message_id) do
    source_message_id(patch) == source_message_id and patch["current_state"] == current_state
  end

  defp already_applied?(_artifact, _patch), do: false

  defp update_draft(%Artifact{} = artifact, %ArtifactLink{} = link, patch) do
    next_data = draft_data(artifact.data || %{}, patch)
    next_metadata = next_link_metadata(link, patch)

    with {:ok, updated_artifact} <- update_artifact_if_changed(artifact, next_data),
         {:ok, updated_link} <- update_link_if_changed(link, next_metadata) do
      {:ok, %{artifact: updated_artifact, link: updated_link}}
    end
  end

  defp next_link_metadata(%ArtifactLink{metadata: metadata}, patch) do
    metadata
    |> Kernel.||(%{})
    |> Map.take(["provenance"])
    |> Map.merge(link_metadata(patch))
  end

  defp update_artifact_if_changed(%Artifact{data: data} = artifact, data), do: {:ok, artifact}

  defp update_artifact_if_changed(%Artifact{} = artifact, data) do
    ArtifactsRepo.update(artifact, %{data: data})
  end

  defp update_link_if_changed(%ArtifactLink{metadata: metadata} = link, metadata), do: {:ok, link}

  defp update_link_if_changed(%ArtifactLink{} = link, metadata) do
    ArtifactLinks.update(link, %{metadata: metadata})
  end

  defp existing_draft(%ChatSession{} = chat_session, state_machine_id) do
    chat_session
    |> existing_draft_query(state_machine_id)
    |> Repo.one()
  end

  defp existing_draft_query(%ChatSession{} = chat_session, state_machine_id) do
    from artifact in Artifact,
      join: link in ArtifactLink,
      on: link.artifact_id == artifact.id,
      where:
        artifact.user_id == ^chat_session.user_id and
          artifact.project_id == ^chat_session.project_id and
          artifact.artifact_type == @artifact_type and artifact.artifact_state == @artifact_state and
          fragment("?->>? = ?", artifact.data, "state_machine_id", ^state_machine_id),
      where:
        link.user_id == ^chat_session.user_id and link.project_id == ^chat_session.project_id and
          link.subject_type == @subject_type and link.subject_id == ^chat_session.id and
          link.relationship_kind == @relationship_kind,
      order_by: [desc: artifact.updated_at, desc: artifact.id],
      limit: 1,
      select: {artifact, link}
  end

  defp draft_data(existing_data, patch) do
    existing_data
    |> merge_replace_fields(patch)
    |> merge_append_fields(patch)
  end

  defp merge_replace_fields(data, patch) do
    Enum.reduce(@replace_fields, data, fn field, acc ->
      if Map.has_key?(patch, field), do: Map.put(acc, field, patch[field]), else: acc
    end)
  end

  defp merge_append_fields(data, patch) do
    Enum.reduce(@append_fields, data, fn field, acc ->
      case Map.fetch(patch, field) do
        {:ok, values} when is_list(values) ->
          Map.put(acc, field, Map.get(acc, field, []) ++ values)

        _ ->
          acc
      end
    end)
  end

  defp link_metadata(patch) do
    Map.take(patch, ["state_machine_id", "current_state", "revision", "source_chat"])
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_value(value)} end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(values) when is_list(values), do: Enum.map(values, &stringify_value/1)
  defp stringify_value(value), do: value
end
