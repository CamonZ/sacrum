defmodule SacrumWeb.ProjectJSON do
  alias Sacrum.Repo.Schemas.Project

  def index(%{projects: projects}) do
    %{data: for(project <- projects, do: data(project))}
  end

  def show(%{project: project}) do
    %{data: data(project)}
  end

  defp data(%Project{} = project) do
    %{
      id: project.id,
      name: project.name,
      slug: project.slug,
      description: project.description,
      inserted_at: project.inserted_at,
      updated_at: project.updated_at
    }
  end
end
