defmodule Sacrum.Repo.ReviewThreads do
  @moduledoc "Scoped queries for anchored chat discussions."
  import Ecto.Query
  alias Sacrum.Repo.Schemas.ReviewThread

  @spec scope(String.t(), String.t(), String.t()) :: Ecto.Query.t()
  def scope(user_id, project_id, installation_id) do
    from thread in ReviewThread,
      where:
        thread.user_id == ^user_id and thread.project_id == ^project_id and
          thread.installation_id == ^installation_id
  end
end
