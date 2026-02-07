defmodule SacrumWeb.Graphql.Types.ProjectType do
  @moduledoc """
  GraphQL type definition for Project resource.
  """

  use Absinthe.Schema.Notation
  import Absinthe.Resolution.Helpers

  alias Sacrum.Accounts

  object :project do
    field :id, :id
    field :name, :string
    field :slug, :string
    field :description, :string
    field :inserted_at, :datetime
    field :updated_at, :datetime

    # Associations
    field :workflows, list_of(:workflow) do
      resolve(dataloader(Sacrum.Accounts.Workflows))
    end
  end

  object :project_queries do
    field :projects, list_of(:project) do
      resolve(fn _args, %{context: %{current_user: user}} ->
        projects = Accounts.Projects.list_by(user.id)
        {:ok, projects}
      end)
    end

    field :project, :project do
      arg :id, non_null(:uuid4)

      resolve(fn %{id: id}, %{context: %{current_user: user}} ->
        case Accounts.Projects.get_by(user.id, conditions: [id: id]) do
          {:ok, project} -> {:ok, project}
          error -> error
        end
      end)
    end
  end

  object :project_mutations do
    field :create_project, :project do
      arg :name, non_null(:string)
      arg :description, :string
      arg :slug, :string

      resolve(fn args, %{context: %{current_user: user}} ->
        Accounts.Projects.insert(user.id, args)
      end)
    end

    field :update_project, :project do
      arg :id, non_null(:uuid4)
      arg :name, :string
      arg :description, :string
      arg :slug, :string

      resolve(fn %{id: id} = args, %{context: %{current_user: user}} ->
        with {:ok, project} <- Accounts.Projects.get_by(user.id, conditions: [id: id]) do
          attrs = Map.drop(args, [:id])
          Accounts.Projects.update(project, attrs)
        end
      end)
    end

    field :delete_project, :project do
      arg :id, non_null(:uuid4)

      resolve(fn %{id: id}, %{context: %{current_user: user}} ->
        with {:ok, project} <- Accounts.Projects.get_by(user.id, conditions: [id: id]) do
          Accounts.Projects.delete(project)
        end
      end)
    end
  end
end
