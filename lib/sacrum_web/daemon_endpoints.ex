defmodule SacrumWeb.DaemonEndpoints do
  @moduledoc "Canonical daemon endpoints from trusted deployment configuration."

  @spec base_url() :: {:ok, String.t()} | {:error, String.t()}
  def base_url do
    configured = Application.get_env(:sacrum, :daemon_external_url, SacrumWeb.Endpoint.url())
    normalize(configured)
  end

  @spec normalize(term()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize(value) when is_binary(value) do
    with {:ok, uri} <- URI.new(value),
         true <- uri.scheme in ["http", "https"],
         true <- is_binary(uri.host) and uri.host != "",
         true <- is_integer(uri.port) and uri.port in 1..65_535,
         true <- is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
         true <- valid_path?(uri.path) do
      {:ok, URI.to_string(%{uri | path: String.trim_trailing(uri.path || "", "/")})}
    else
      _ -> {:error, "Daemon endpoint is not configured correctly"}
    end
  end

  def normalize(_), do: {:error, "Daemon endpoint is not configured correctly"}

  @spec socket_url(String.t()) :: String.t()
  def socket_url(base_url) do
    uri = URI.parse(base_url)

    URI.to_string(%{
      uri
      | scheme: if(uri.scheme == "https", do: "wss", else: "ws"),
        path: (uri.path || "") <> "/socket/websocket"
    })
  end

  defp valid_path?(nil), do: true

  defp valid_path?(path) do
    String.starts_with?(path, "/") and
      not Enum.any?(String.split(URI.decode(path), "/"), &(&1 in [".", ".."])) and
      not String.contains?(path, ["\\", " "])
  end
end
