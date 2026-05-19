defmodule Sacrum.Repo.ArtifactLinks do
  @moduledoc """
  Database operations for artifact links.
  """

  use Sacrum.GenericRepo, schema: Sacrum.Repo.Schemas.ArtifactLink

  import Ecto.Query
  import Sacrum.Chat.Guards

  alias Sacrum.Repo
  alias Sacrum.Repo.Schemas.Artifact
  alias Sacrum.Repo.Schemas.ArtifactLink
  alias Sacrum.Repo.Schemas.ChatSession
  alias Sacrum.Repo.Schemas.Task
  alias Sacrum.Repo.Schemas.TaskSection

  @spec insert(String.t(), String.t(), String.t(), map()) ::
          {:ok, ArtifactLink.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :artifact_scope_mismatch}
          | {:error, :subject_scope_mismatch}
  def insert(user_id, project_id, artifact_id, attrs)
      when is_user_project_scope(user_id, project_id) and is_binary(artifact_id) and
             is_attrs(attrs) do
    with :ok <- artifact_in_scope?(user_id, project_id, artifact_id),
         :ok <- subject_in_scope?(user_id, project_id, attrs) do
      %ArtifactLink{user_id: user_id, project_id: project_id, artifact_id: artifact_id}
      |> ArtifactLink.create_changeset(attrs)
      |> Repo.insert()
    end
  end

  @spec list_by_subject(String.t(), String.t(), String.t(), String.t()) :: [ArtifactLink.t()]
  def list_by_subject(user_id, project_id, subject_type, subject_id)
      when is_user_project_scope(user_id, project_id) and is_binary(subject_type) and
             is_binary(subject_id) do
    ArtifactLink
    |> where(
      [link],
      link.user_id == ^user_id and link.project_id == ^project_id and
        link.subject_type == ^subject_type and link.subject_id == ^subject_id
    )
    |> order_by([link], desc: link.inserted_at, desc: link.id)
    |> Repo.all()
  end

  @spec list_by_artifact(String.t(), String.t(), String.t()) :: [ArtifactLink.t()]
  def list_by_artifact(user_id, project_id, artifact_id)
      when is_user_project_scope(user_id, project_id) and is_binary(artifact_id) do
    ArtifactLink
    |> where(
      [link],
      link.user_id == ^user_id and link.project_id == ^project_id and
        link.artifact_id == ^artifact_id
    )
    |> order_by([link], desc: link.inserted_at, desc: link.id)
    |> Repo.all()
  end

  defp artifact_in_scope?(user_id, project_id, artifact_id) do
    exists? =
      Artifact
      |> where(
        [artifact],
        artifact.id == ^artifact_id and artifact.user_id == ^user_id and
          artifact.project_id == ^project_id
      )
      |> Repo.exists?()

    if exists?, do: :ok, else: {:error, :artifact_scope_mismatch}
  end

  defp subject_in_scope?(user_id, project_id, %{
         subject_type: subject_type,
         subject_id: subject_id
       }) do
    do_subject_in_scope?(user_id, project_id, subject_type, subject_id)
  end

  defp subject_in_scope?(user_id, project_id, %{
         "subject_type" => subject_type,
         "subject_id" => subject_id
       }) do
    do_subject_in_scope?(user_id, project_id, subject_type, subject_id)
  end

  defp subject_in_scope?(_user_id, _project_id, _attrs), do: :ok

  defp do_subject_in_scope?(user_id, project_id, subject_type, subject_id)
       when is_binary(subject_type) and is_binary(subject_id) do
    if subject_exists?(user_id, project_id, subject_type, subject_id) do
      :ok
    else
      {:error, :subject_scope_mismatch}
    end
  end

  defp do_subject_in_scope?(_user_id, _project_id, _subject_type, _subject_id), do: :ok

  defp subject_exists?(user_id, project_id, "task", subject_id) do
    Task
    |> where(
      [task],
      task.id == ^subject_id and task.user_id == ^user_id and task.project_id == ^project_id
    )
    |> Repo.exists?()
  end

  defp subject_exists?(user_id, project_id, "task_section", subject_id) do
    TaskSection
    |> where(
      [section],
      section.id == ^subject_id and section.user_id == ^user_id and
        section.project_id == ^project_id
    )
    |> Repo.exists?()
  end

  defp subject_exists?(user_id, project_id, "chat_session", subject_id) do
    ChatSession
    |> where(
      [session],
      session.id == ^subject_id and session.user_id == ^user_id and
        session.project_id == ^project_id
    )
    |> Repo.exists?()
  end

  defp subject_exists?(_user_id, _project_id, _subject_type, _subject_id), do: true
end
