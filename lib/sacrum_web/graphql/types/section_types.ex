defmodule SacrumWeb.Graphql.Types.SectionTypes do
  @moduledoc """
  GraphQL type definitions for Section and CodeRef resources.
  """

  use Absinthe.Schema.Notation
  import Absinthe.Resolution.Helpers

  alias Sacrum.Accounts

  object :task_section do
    field :id, :id
    field :section_type, :string
    field :content, :string
    field :section_order, :integer
    field :done, :boolean
    field :done_at, :datetime
    field :inserted_at, :datetime
    field :updated_at, :datetime

    # Associations
    field :task_id, :id

    field :task, :task do
      resolve(dataloader(Accounts.Tasks))
    end

    field :project_id, :id

    field :project, :project do
      resolve(dataloader(Accounts.Projects))
    end

    field :code_refs, list_of(:code_ref) do
      resolve(dataloader(Accounts.CodeRefs))
    end
  end

  object :code_ref do
    field :id, :id
    field :path, :string
    field :line_start, :integer
    field :line_end, :integer
    field :name, :string
    field :description, :string
    field :inserted_at, :datetime
    field :updated_at, :datetime

    # Associations
    field :task_id, :id

    field :task, :task do
      resolve(dataloader(Accounts.Tasks))
    end

    field :section_id, :id

    field :section, :task_section do
      resolve(dataloader(Accounts.Sections))
    end

    field :project_id, :id

    field :project, :project do
      resolve(dataloader(Accounts.Projects))
    end
  end

  object :section_mutations do
    field :create_section, :task_section do
      arg(:task_id, non_null(:uuid4))
      arg(:section_type, non_null(:string))
      arg(:content, non_null(:string))
      arg(:section_order, :integer)
      arg(:done, :boolean)

      resolve(fn args, %{context: %{current_user: user}} ->
        task_id = Map.get(args, :task_id)

        with {:ok, task} <- Accounts.Tasks.find(user.id, task_id) do
          attrs = Map.put(args, :project_id, task.project_id)
          Accounts.Sections.insert(user.id, attrs)
        end
      end)
    end

    field :update_section, :task_section do
      arg(:id, non_null(:uuid4))
      arg(:section_type, :string)
      arg(:content, :string)
      arg(:section_order, :integer)
      arg(:done, :boolean)
      arg(:done_at, :datetime)

      resolve(fn %{id: id} = args, %{context: %{current_user: user}} ->
        with {:ok, section} <- Accounts.Sections.get_by(user.id, conditions: [id: id]) do
          attrs = Map.drop(args, [:id])
          Accounts.Sections.update(section, attrs)
        end
      end)
    end

    field :delete_section, :task_section do
      arg(:id, non_null(:uuid4))

      resolve(fn %{id: id}, %{context: %{current_user: user}} ->
        with {:ok, section} <- Accounts.Sections.get_by(user.id, conditions: [id: id]) do
          Accounts.Sections.delete(section)
        end
      end)
    end

    field :create_code_ref, :code_ref do
      arg(:task_id, :uuid4)
      arg(:section_id, :uuid4)
      arg(:path, non_null(:string))
      arg(:line_start, :integer)
      arg(:line_end, :integer)
      arg(:name, :string)
      arg(:description, :string)

      resolve(fn args, %{context: %{current_user: user}} ->
        task_id = Map.get(args, :task_id)
        section_id = Map.get(args, :section_id)

        case {task_id, section_id} do
          {nil, nil} ->
            {:error, "must provide either task_id or section_id"}

          {task_id, nil} ->
            with {:ok, task} <- Accounts.Tasks.find(user.id, task_id) do
              attrs = Map.put(args, :project_id, task.project_id)
              Accounts.CodeRefs.insert_for_task(user.id, attrs)
            end

          {nil, section_id} ->
            with {:ok, section} <- Accounts.Sections.get_by(user.id, conditions: [id: section_id]) do
              section = Sacrum.Repo.preload(section, :task)
              attrs = Map.put(args, :project_id, section.task.project_id)
              Accounts.CodeRefs.insert_for_section(user.id, attrs)
            end

          {_task_id, _section_id} ->
            {:error, "cannot provide both task_id and section_id"}
        end
      end)
    end

    field :delete_code_ref, :code_ref do
      arg(:id, non_null(:uuid4))

      resolve(fn %{id: id}, %{context: %{current_user: user}} ->
        with {:ok, code_ref} <- Accounts.CodeRefs.get_by(user.id, conditions: [id: id]) do
          Accounts.CodeRefs.delete(code_ref)
        end
      end)
    end

    field :delete_task_code_refs, list_of(:code_ref) do
      arg(:task_id, non_null(:uuid4))

      resolve(fn %{task_id: task_id}, %{context: %{current_user: user}} ->
        Accounts.CodeRefs.delete_task_refs(user.id, task_id)
      end)
    end
  end
end
