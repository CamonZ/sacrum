defmodule Sacrum.Accounts.Artifacts do
  @moduledoc """
  User- and project-scoped operations for artifacts.

  Visibility (public vs internal) is enforced here: callers without an explicit
  `internal: true` opt only see public artifacts.
  """

  alias Sacrum.Accounts.Projects
  alias Sacrum.Repo
  alias Sacrum.Repo.ArtifactLinks
  alias Sacrum.Repo.Artifacts, as: ArtifactsRepo
  alias Sacrum.Repo.Schemas.{Artifact, ArtifactLink}

  @spec create(String.t(), String.t(), map()) ::
          {:ok, Artifact.t()} | {:error, :unauthorized | Ecto.Changeset.t() | :not_found}
  def create(user_id, project_id, attrs)
      when is_binary(user_id) and is_binary(project_id) and is_map(attrs) do
    case Projects.get_by(user_id, conditions: [id: project_id]) do
      {:ok, _project} ->
        ArtifactsRepo.create(user_id, project_id, prepare_create_attrs(attrs))

      {:error, :not_found} ->
        {:error, :unauthorized}
    end
  end

  @spec update(String.t(), String.t(), String.t(), map()) ::
          {:ok, Artifact.t()}
          | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def update(user_id, artifact_id, project_id, attrs) do
    case ArtifactsRepo.get_for_project(user_id, artifact_id, project_id, internal: true) do
      {:ok, artifact} ->
        artifact
        |> Artifact.changeset(prepare_update_attrs(artifact, attrs))
        |> Repo.update()

      {:error, :not_found} ->
        case Repo.get(Artifact, artifact_id) do
          nil -> {:error, :not_found}
          _ -> {:error, :unauthorized}
        end
    end
  end

  @spec delete(String.t(), String.t(), String.t()) ::
          {:ok, Artifact.t()} | {:error, :unauthorized | :not_found | Ecto.Changeset.t()}
  def delete(user_id, artifact_id, project_id) do
    case ArtifactsRepo.get_for_project(user_id, artifact_id, project_id, internal: true) do
      {:ok, artifact} ->
        Repo.delete(artifact)

      {:error, :not_found} ->
        case Repo.get(Artifact, artifact_id) do
          nil -> {:error, :not_found}
          _ -> {:error, :unauthorized}
        end
    end
  end

  defp prepare_create_attrs(attrs) do
    name = fetch(attrs, :name)

    attrs
    |> put_new(:title, fetch(attrs, :title) || name || "Untitled")
    |> put_new(:content, fetch(attrs, :content) || fetch(attrs, :description))
    |> put_new(:storage_ref, fetch(attrs, :storage_ref) || fetch(attrs, :url))
    |> put_new(:artifact_type, fetch(attrs, :artifact_type) || "file")
    |> put_new(:artifact_state, fetch(attrs, :artifact_state) || "draft")
    |> put_new(:visibility, fetch(attrs, :visibility) || "public")
    |> put_new(:redaction_state, fetch(attrs, :redaction_state) || "not_needed")
  end

  defp prepare_update_attrs(%Artifact{} = artifact, attrs) do
    attrs =
      case fetch(attrs, :name) do
        nil -> attrs
        name -> Map.put(put_new(attrs, :title, fetch(attrs, :title) || name), :name, name)
      end

    attrs
    |> put_new(:artifact_type, fetch(attrs, :artifact_type) || artifact.artifact_type)
    |> put_new(:artifact_state, fetch(attrs, :artifact_state) || artifact.artifact_state)
    |> put_new(:visibility, fetch(attrs, :visibility) || artifact.visibility)
    |> put_new(:title, fetch(attrs, :title) || artifact.title)
  end

  defp fetch(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp put_new(attrs, key, value) do
    cond do
      Map.has_key?(attrs, key) and not is_nil(Map.get(attrs, key)) ->
        attrs

      Map.has_key?(attrs, Atom.to_string(key)) and not is_nil(Map.get(attrs, Atom.to_string(key))) ->
        attrs

      true ->
        Map.put(attrs, key, value)
    end
  end

  @spec get_for_project(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Artifact.t()} | {:error, :not_found}
  def get_for_project(user_id, artifact_id, project_id, opts \\ []) do
    ArtifactsRepo.get_for_project(user_id, artifact_id, project_id, opts)
  end

  @spec list_by_project(String.t(), String.t(), keyword()) :: [Artifact.t()]
  def list_by_project(user_id, project_id, opts \\ []) do
    ArtifactsRepo.list_by_project(user_id, project_id, opts)
  end

  @spec list_for_subject(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          [Artifact.t()]
  def list_for_subject(user_id, subject_type, subject_id, project_id, opts \\ []) do
    ArtifactsRepo.list_for_subject(user_id, subject_type, subject_id, project_id, opts)
  end

  @spec add_link(String.t(), String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, ArtifactLink.t()} | {:error, :unauthorized | Ecto.Changeset.t() | :not_found}
  def add_link(user_id, artifact_id, subject_type, subject_id, project_id, opts \\ [])
      when is_binary(user_id) and is_binary(artifact_id) and is_binary(subject_type) and
             is_binary(subject_id) and is_binary(project_id) do
    relationship_kind = Keyword.get(opts, :relationship_kind, "attached_to")
    metadata = Keyword.get(opts, :metadata)

    case ArtifactsRepo.get_for_project(user_id, artifact_id, project_id, internal: true) do
      {:ok, artifact} ->
        ArtifactLinks.add_link(%{
          artifact_id: artifact.id,
          subject_type: subject_type,
          subject_id: subject_id,
          relationship_kind: relationship_kind,
          project_id: project_id,
          user_id: user_id,
          metadata: metadata
        })

      {:error, :not_found} ->
        {:error, :unauthorized}
    end
  end
end
