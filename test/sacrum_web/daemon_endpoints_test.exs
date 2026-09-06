defmodule SacrumWeb.DaemonEndpointsTest do
  use ExUnit.Case, async: false

  alias SacrumWeb.DaemonEndpoints

  setup do
    original = Application.fetch_env(:sacrum, :daemon_external_url)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:sacrum, :daemon_external_url, value)
        :error -> Application.delete_env(:sacrum, :daemon_external_url)
      end
    end)
  end

  test "canonical schemes, ports and proxy paths produce matching websocket endpoints" do
    for {base, expected, socket} <- [
          {"http://localhost:4200", "http://localhost:4200",
           "ws://localhost:4200/socket/websocket"},
          {"https://fleet.example:8443/proxy/", "https://fleet.example:8443/proxy",
           "wss://fleet.example:8443/proxy/socket/websocket"},
          {"https://fleet.example", "https://fleet.example",
           "wss://fleet.example/socket/websocket"},
          {"http://[::1]:4200", "http://[::1]:4200", "ws://[::1]:4200/socket/websocket"}
        ] do
      Application.put_env(:sacrum, :daemon_external_url, base)
      assert {:ok, ^expected} = DaemonEndpoints.base_url()
      assert DaemonEndpoints.socket_url(expected) == socket
    end
  end

  test "absent override falls back to trusted endpoint including listener port" do
    Application.delete_env(:sacrum, :daemon_external_url)
    assert {:ok, endpoint} = DaemonEndpoints.base_url()
    assert endpoint == SacrumWeb.Endpoint.url()
    assert URI.parse(endpoint).port == SacrumWeb.Endpoint.config(:http)[:port]
  end

  test "invalid deployment endpoints return a sanitized configuration error" do
    for invalid <- [
          nil,
          "",
          "fleet.example",
          "ftp://fleet.example",
          "https://user:secret@fleet.example",
          "https://fleet.example?token=x",
          "https://fleet.example#fragment",
          "https://fleet.example:0",
          "https://fleet.example:70000",
          "https://fleet.example/a/../b",
          "https://fleet.example/a/%2E%2E/b"
        ] do
      Application.put_env(:sacrum, :daemon_external_url, invalid)
      assert {:error, "Daemon endpoint is not configured correctly"} = DaemonEndpoints.base_url()
    end
  end
end
