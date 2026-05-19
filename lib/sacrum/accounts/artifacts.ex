defmodule Sacrum.Accounts.Artifacts do
  @moduledoc """
  User-scoped artifact operations.

  Artifacts are generic records that can be attached to supported subjects
  without depending on API resolver or chat-run modules.
  """

  alias Sacrum.Repo
  alias Sacrum.Repo.ArtifactLinks
  alias Sacrum.Repo.Artifacts, as: ArtifactsRepo
  alias Sacrum.Repo.Schemas.{Artifact, ArtifactLink}

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
        %{artifact: artifact, link: link}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  List public, redaction-safe artifacts attached to a subject.
  """
  @spec list_for_subject(String.t(), String.t(), String.t(), String.t()) :: [Artifact.t()]
  def list_for_subject(user_id, project_id, subject_type, subject_id)
      when is_binary(user_id) and is_binary(project_id) and is_binary(subject_type) and
             is_binary(subject_id) do
    ArtifactsRepo.list_public_for_subject(user_id, project_id, subject_type, subject_id)
  end
end
