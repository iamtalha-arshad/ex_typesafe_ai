defmodule TypeSafe.HTTP do
  @moduledoc false
  # Internal request dispatch: sends a request through the client's `Req` instance, then maps the
  # outcome onto the SDK's success structs and exception structs.

  alias TypeSafe.Client

  @request_id_header "x-typesafe-request-id"

  @typedoc "A function that decodes a successful response body into a public struct."
  @type parser :: (term(), TypeSafe.Response.meta() ->
                     {:ok, struct()} | {:error, TypeSafe.Error.t()})

  @spec request(Client.t(), atom(), String.t(), keyword(), parser()) ::
          {:ok, struct()} | {:error, TypeSafe.Error.t()}
  def request(%Client{} = client, method, path, req_opts, parser) do
    endpoint = "#{method |> to_string() |> String.upcase()} #{client.config.base_url}#{path}"

    case Req.request(client.req, [method: method, url: path] ++ req_opts) do
      {:ok, %Req.Response{} = response} ->
        handle_response(response, endpoint, parser)

      {:error, exception} ->
        {:error, transport_error(exception, client.config.timeout)}
    end
  end

  defp handle_response(%Req.Response{status: status} = response, endpoint, parser) do
    headers = normalize_headers(response.headers)
    request_id = Map.get(headers, @request_id_header)

    if status in 200..299 do
      meta = %{
        status: status,
        headers: headers,
        request_id: request_id,
        endpoint: endpoint,
        raw: response
      }

      parser.(response.body, meta)
    else
      {:error, TypeSafe.Error.api_error(status, response.body, headers, endpoint)}
    end
  end

  # Req represents headers as a map of lowercased names to a list of values. Collapse to the first
  # value, which is all the SDK needs (request id, retry-after).
  defp normalize_headers(headers) do
    Map.new(headers, fn
      {name, [value | _]} -> {name, value}
      {name, value} -> {name, value}
    end)
  end

  defp transport_error(%{reason: :timeout}, timeout) do
    %TypeSafe.TimeoutError{message: "Request timed out (timeout=#{timeout}ms).", timeout: timeout}
  end

  defp transport_error(exception, _timeout) when is_exception(exception) do
    %TypeSafe.ConnectionError{
      message: "Connection error: #{Exception.message(exception)}",
      reason: exception
    }
  end

  defp transport_error(reason, _timeout) do
    %TypeSafe.ConnectionError{message: "Connection error: #{inspect(reason)}", reason: reason}
  end
end
