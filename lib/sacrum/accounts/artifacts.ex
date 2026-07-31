defmodule Sacrum.Accounts.Artifacts do
  @moduledoc """
  User-scoped artifact operations.

  Artifacts are project-scoped files that can be attached to supported subjects
  without depending on API resolver modules.
  """

  alias Sacrum.Repo
  alias Sacrum.Repo.ArtifactLinks
  alias Sacrum.Repo.Artifacts, as: ArtifactsRepo
  alias Sacrum.Repo.Schemas.{Artifact, ArtifactLink, ArtifactLinkMetadata}

  @doc """
  Retrieve an artifact in the caller's ownership scope.
  """
  @spec get(String.t(), String.t()) :: {:ok, Artifact.t()} | {:error, :not_found}
  def get(user_id, artifact_id) when is_binary(user_id) and is_binary(artifact_id) do
    ArtifactsRepo.get_in_scope(user_id, artifact_id)
  end

  @doc """
  Create an artifact and attach it to a supported subject.
  """
  @spec create_and_link(String.t(), String.t(), map(), map()) ::
          {:ok, %{artifact: Artifact.t(), link: ArtifactLink.t()}}
          | {:error, Ecto.Changeset.t()}
          | {:error, :not_found | :artifact_scope_mismatch | :subject_scope_mismatch}
  def create_and_link(user_id, project_id, artifact_attrs, link_attrs)
      when is_binary(user_id) and is_binary(project_id) and is_map(artifact_attrs) and
             is_map(link_attrs) do
    Repo.transaction(fn ->
      with {:ok, artifact} <- ArtifactsRepo.insert(user_id, project_id, artifact_attrs),
           {:ok, link} <- ArtifactLinks.insert(user_id, project_id, artifact.id, link_attrs) do
        %{artifact: artifact_with_link(artifact, link), link: link}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Update an artifact and optionally replace its sole attachment.

  Attachment replacement preserves the existing metadata unless the caller
  supplies a replacement value.
  Artifacts with multiple links require callers to update file fields without
  changing attachments.
  """
  @spec update(String.t(), String.t(), map(), map() | nil) ::
          {:ok, Artifact.t()}
          | {:error,
             Ecto.Changeset.t()
             | :not_found
             | :artifact_scope_mismatch
             | :subject_scope_mismatch
             | :ambiguous_attachment}
  def update(user_id, artifact_id, artifact_attrs, attachment_attrs \\ nil)
      when is_binary(user_id) and is_binary(artifact_id) and is_map(artifact_attrs) and
             (is_map(attachment_attrs) or is_nil(attachment_attrs)) do
    Repo.transaction(fn ->
      with {:ok, artifact} <- ArtifactsRepo.get_in_scope_for_update(user_id, artifact_id),
           {:ok, updated_artifact} <- ArtifactsRepo.update(artifact, artifact_attrs),
           {:ok, link} <- maybe_update_attachment(updated_artifact, attachment_attrs) do
        artifact_with_optional_link(updated_artifact, link)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  Delete an artifact owned by the user. Its links are deleted by the database cascade.
  """
  @spec delete(String.t(), String.t()) ::
          {:ok, Artifact.t()} | {:error, Ecto.Changeset.t() | :not_found}
  def delete(user_id, artifact_id) when is_binary(user_id) and is_binary(artifact_id) do
    with {:ok, artifact} <- ArtifactsRepo.get_in_scope(user_id, artifact_id) do
      ArtifactsRepo.delete(artifact)
    end
  end

  @doc """
  List artifacts attached to a subject within the caller's user and project scope.
  """
  @spec list_for_subject(String.t(), String.t(), String.t(), String.t(), keyword()) :: [
          Artifact.t()
        ]
  def list_for_subject(user_id, project_id, subject_type, subject_id, opts \\ [])
      when is_binary(user_id) and is_binary(project_id) and is_binary(subject_type) and
             is_binary(subject_id) and is_list(opts) do
    ArtifactsRepo.list_for_subject(user_id, project_id, subject_type, subject_id, opts)
  end

  @doc """
  Retrieve an artifact attached to a subject by its stable per-link logical name.
  """
  @spec get_for_subject_by_logical_name(
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) ::
          {:ok, Artifact.t()} | {:error, :not_found}
  def get_for_subject_by_logical_name(user_id, project_id, subject_type, subject_id, logical_name)
      when is_binary(user_id) and is_binary(project_id) and is_binary(subject_type) and
             is_binary(subject_id) and is_binary(logical_name) do
    ArtifactsRepo.get_for_subject_by_logical_name(
      user_id,
      project_id,
      subject_type,
      subject_id,
      logical_name
    )
  end

  defp maybe_update_attachment(_artifact, nil), do: {:ok, nil}

  defp maybe_update_attachment(%Artifact{} = artifact, %{subject_type: _, subject_id: _} = attrs) do
    maybe_replace_attachment(artifact, attrs)
  end

  defp maybe_update_attachment(
         %Artifact{} = artifact,
         %{
           "subject_type" => _,
           "subject_id" => _
         } = attrs
       ) do
    maybe_replace_attachment(artifact, attrs)
  end

  defp maybe_update_attachment(%Artifact{} = artifact, attrs) do
    case ArtifactLinks.list_by_artifact(artifact.user_id, artifact.project_id, artifact.id) do
      [link] -> ArtifactLinks.update(link, attrs)
      [] -> {:error, :not_found}
      [_first, _second | _rest] -> {:error, :ambiguous_attachment}
    end
  end

  defp maybe_replace_attachment(%Artifact{} = artifact, attachment_attrs) do
    case ArtifactLinks.list_by_artifact(artifact.user_id, artifact.project_id, artifact.id) do
      [] -> insert_replacement_link(artifact, attachment_attrs, %{})
      [link] -> replace_link(artifact, link, attachment_attrs)
      [_first, _second | _rest] -> {:error, :ambiguous_attachment}
    end
  end

  defp replace_link(artifact, link, attachment_attrs) do
    with {:ok, replacement} <-
           insert_replacement_link(
             artifact,
             attachment_attrs,
             link.metadata,
             link.logical_name
           ),
         {:ok, _deleted_link} <- ArtifactLinks.delete(link) do
      {:ok, replacement}
    end
  end

  defp insert_replacement_link(
         artifact,
         attachment_attrs,
         metadata,
         logical_name \\ nil
       ) do
    logical_name = attachment_logical_name(attachment_attrs, logical_name)

    attrs =
      attachment_attrs
      |> Map.delete("logical_name")
      |> Map.put(:metadata, metadata_params(metadata))
      |> Map.put(:logical_name, logical_name)

    ArtifactLinks.insert(artifact.user_id, artifact.project_id, artifact.id, attrs)
  end

  defp attachment_logical_name(attrs, default) do
    cond do
      Map.has_key?(attrs, :logical_name) -> Map.fetch!(attrs, :logical_name)
      Map.has_key?(attrs, "logical_name") -> Map.fetch!(attrs, "logical_name")
      true -> default
    end
  end

  defp artifact_with_link(artifact, link) do
    %{
      artifact
      | logical_name: link.logical_name,
        metadata: metadata_params(link.metadata)
    }
  end

  defp artifact_with_optional_link(artifact, nil), do: artifact
  defp artifact_with_optional_link(artifact, link), do: artifact_with_link(artifact, link)

  defp metadata_params(%ArtifactLinkMetadata{
         version: nil,
         content_kind: nil,
         format: nil,
         origin: nil,
         presentation: nil,
         extensions: nil
       }),
       do: nil

  defp metadata_params(%ArtifactLinkMetadata{} = metadata) do
    %{
      "version" => metadata.version,
      "content_kind" => metadata.content_kind,
      "format" => metadata.format,
      "origin" => metadata.origin,
      "presentation" => metadata.presentation,
      "extensions" => metadata.extensions
    }
  end

  defp metadata_params(metadata), do: metadata
end
