defmodule SacrumWeb.FallbackControllerTest do
  use SacrumWeb.ConnCase, async: true

  alias SacrumWeb.FallbackController
  alias Sacrum.Repo.Schemas.User

  describe "call/2 with changeset error" do
    test "returns 422 with changeset errors" do
      changeset =
        Ecto.Changeset.add_error(
          Ecto.Changeset.change(%User{}, %{}),
          :email,
          "is invalid"
        )

      conn = build_conn(:post, "/api/users")
      conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
      conn = put_format(conn, "json")
      conn = FallbackController.call(conn, {:error, changeset})

      assert conn.status == 422
      response = json_response(conn, 422)
      assert response["errors"]["email"] != nil
    end
  end

  describe "call/2 with not_found error" do
    test "returns 404 for :not_found error" do
      conn = build_conn(:get, "/api/users/not-found")
      conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
      conn = put_format(conn, "json")
      conn = FallbackController.call(conn, {:error, :not_found})

      assert conn.status == 404
    end
  end

  defp put_format(conn, format) do
    conn
    |> put_private(:phoenix_format, format)
    |> Map.put(:params, Map.put(conn.params, "_format", format))
  end

  describe "call/2 with unprocessable_entity error with message" do
    test "returns 422 with custom message" do
      conn = build_conn(:post, "/api/tasks")
      conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
      conn = put_format(conn, "json")

      conn =
        FallbackController.call(conn, {:error, :unprocessable_entity, "Custom error message"})

      assert conn.status == 422
      response = json_response(conn, 422)
      assert response["errors"]["detail"] == "Custom error message"
    end
  end

  describe "call/2 with domain-specific atom errors" do
    test "returns 422 for :circular_dependency error" do
      conn = build_conn(:post, "/api/task-dependencies")
      conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
      conn = put_format(conn, "json")
      conn = FallbackController.call(conn, {:error, :circular_dependency})

      assert conn.status == 422
      response = json_response(conn, 422)
      assert response["errors"]["detail"] == "circular_dependency"
    end

    test "returns 422 for :no_workflow error" do
      conn = build_conn(:post, "/api/task-workflows/move")
      conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
      conn = put_format(conn, "json")
      conn = FallbackController.call(conn, {:error, :no_workflow})

      assert conn.status == 422
      response = json_response(conn, 422)
      assert response["errors"]["detail"] == "no_workflow"
    end

    test "returns 422 for :different_projects error" do
      conn = build_conn(:post, "/api/task-dependencies")
      conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
      conn = put_format(conn, "json")
      conn = FallbackController.call(conn, {:error, :different_projects})

      assert conn.status == 422
      response = json_response(conn, 422)
      assert response["errors"]["detail"] == "different_projects"
    end

    test "returns 422 for :self_dependency error" do
      conn = build_conn(:post, "/api/task-dependencies")
      conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
      conn = put_format(conn, "json")
      conn = FallbackController.call(conn, {:error, :self_dependency})

      assert conn.status == 422
      response = json_response(conn, 422)
      assert response["errors"]["detail"] == "self_dependency"
    end

    test "returns 422 for :no_transition error" do
      conn = build_conn(:post, "/api/task-workflows/move")
      conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
      conn = put_format(conn, "json")
      conn = FallbackController.call(conn, {:error, :no_transition})

      assert conn.status == 422
      response = json_response(conn, 422)
      assert response["errors"]["detail"] == "no_transition"
    end

    test "returns 422 for :different_workflows error" do
      conn = build_conn(:post, "/api/workflow-steps/sync-transitions")
      conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
      conn = put_format(conn, "json")
      conn = FallbackController.call(conn, {:error, :different_workflows})

      assert conn.status == 422
      response = json_response(conn, 422)
      assert response["errors"]["detail"] == "different_workflows"
    end

    test "returns 422 for :duplicate_to_step_ids error" do
      conn = build_conn(:post, "/api/workflow-steps/sync-transitions")
      conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
      conn = put_format(conn, "json")
      conn = FallbackController.call(conn, {:error, :duplicate_to_step_ids})

      assert conn.status == 422
      response = json_response(conn, 422)
      assert response["errors"]["detail"] == "duplicate_to_step_ids"
    end
  end

  describe "call/2 with unexpected error shapes (catch-all)" do
    test "returns 500 for unexpected error tuple" do
      conn = build_conn(:post, "/api/unknown")
      conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
      conn = put_format(conn, "json")
      conn = FallbackController.call(conn, {:unexpected, :error, :shape})

      assert conn.status == 500
      response = json_response(conn, 500)
      assert response["errors"]["detail"] == "An unexpected error occurred"
    end

    test "returns 500 for non-tuple error" do
      conn = build_conn(:post, "/api/unknown")
      conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
      conn = put_format(conn, "json")
      conn = FallbackController.call(conn, "invalid error")

      assert conn.status == 500
      response = json_response(conn, 500)
      assert response["errors"]["detail"] == "An unexpected error occurred"
    end

    test "returns 500 for nil error" do
      conn = build_conn(:post, "/api/unknown")
      conn = Plug.Parsers.call(conn, Plug.Parsers.init(parsers: [:json], json_decoder: Jason))
      conn = put_format(conn, "json")
      conn = FallbackController.call(conn, nil)

      assert conn.status == 500
      response = json_response(conn, 500)
      assert response["errors"]["detail"] == "An unexpected error occurred"
    end
  end
end
