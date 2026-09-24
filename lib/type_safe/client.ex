defmodule TypeSafe.Client do
  @moduledoc """
  A configured TypeSafe API client.

  Build one with `TypeSafe.new/1` (or `TypeSafe.Client.new/1`) and pass it to `TypeSafe.system_one/4`
  and `TypeSafe.list_models/2`. The struct wraps a reusable `Req.Request` holding the base URL,
  authentication, default headers and retry policy, plus the default model.

  A client is an immutable value: it starts no processes and is safe to build once and share across
  processes and requests.
  """

  alias TypeSafe.Config

  @enforce_keys [:req, :config]
  defstruct [:req, :config]

  @type t :: %__MODULE__{req: Req.Request.t(), config: Config.t()}

  @retry_statuses [408, 429]

  @doc """
  Build a client. See `TypeSafe.new/1` for the full list of options.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    config = Config.resolve!(opts)

    req =
      [
        base_url: config.base_url,
        auth: {:bearer, config.api_key},
        headers: default_headers(config),
        receive_timeout: config.timeout,
        retry: Keyword.get(opts, :retry, &default_retry/2),
        max_retries: Keyword.get(opts, :max_retries, 2),
        decode_body: true
      ]
      |> maybe_put(:retry_delay, opts[:retry_delay])
      |> maybe_put(:plug, opts[:plug])
      |> Keyword.merge(Keyword.get(opts, :req_options, []))
      |> Req.new()

    %__MODULE__{req: req, config: config}
  end

  defp default_headers(%Config{headers: headers}) do
    Map.merge(
      %{
        "accept" => "application/json",
        "user-agent" => "#{TypeSafe.sdk_name()}/#{TypeSafe.version()}",
        "x-typesafe-sdk" => "#{TypeSafe.sdk_name()}/#{TypeSafe.version()}",
        "x-typesafe-runtime" => runtime()
      },
      headers
    )
  end

  defp runtime do
    "elixir/#{System.version()} (otp/#{System.otp_release()})"
  end

  # Retry idempotent evaluation on transient statuses and any transport-level exception, mirroring the
  # other TypeSafe SDKs. Returning `true` lets Req apply its backoff, honoring `Retry-After` when set.
  defp default_retry(_request, %Req.Response{status: status}) do
    status in @retry_statuses or status >= 500
  end

  defp default_retry(_request, exception) when is_exception(exception), do: true
  defp default_retry(_request, _other), do: false

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
