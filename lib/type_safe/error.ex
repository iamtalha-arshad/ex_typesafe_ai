defmodule TypeSafe.Error do
  @moduledoc """
  Exception structs used by the SDK.

  Every SDK failure surfaces as one of these structs. Functions that can fail return them in an
  `{:error, exception}` tuple, and the `!` variants raise them. All the HTTP-level exceptions
  (`TypeSafe.APIError` and its siblings) share the same fields — `:status`, `:body`, `:headers`,
  `:request_id`, `:endpoint` and `:message` — so a single `rescue`/pattern can inspect any of them.

  ## Categories

    * `TypeSafe.ConfigError` — invalid configuration or input discovered before a request is sent
      (missing API key, empty questions, an unserializable body).
    * `TypeSafe.ConnectionError` — the request never produced an HTTP response.
    * `TypeSafe.TimeoutError` — the request exceeded its configured timeout (a `ConnectionError`).
    * `TypeSafe.ResponseValidationError` — a 2xx response whose body did not match the schema.
    * `TypeSafe.APIError` and the per-status structs below — the server returned an error status.

  ## Status mapping

  | Status | Exception |
  | ------ | --------- |
  | 400 | `TypeSafe.BadRequestError` |
  | 401 | `TypeSafe.AuthenticationError` |
  | 403 | `TypeSafe.PermissionDeniedError` |
  | 404 | `TypeSafe.NotFoundError` |
  | 422 | `TypeSafe.UnprocessableEntityError` |
  | 429 | `TypeSafe.RateLimitError` |
  | 5xx | `TypeSafe.InternalServerError` |
  | other | `TypeSafe.APIError` |
  """

  @typedoc "Any exception struct the SDK may raise or return."
  @type t ::
          TypeSafe.ConfigError.t()
          | TypeSafe.ConnectionError.t()
          | TypeSafe.TimeoutError.t()
          | TypeSafe.ResponseValidationError.t()
          | TypeSafe.APIError.t()

  @status_modules %{
    400 => TypeSafe.BadRequestError,
    401 => TypeSafe.AuthenticationError,
    403 => TypeSafe.PermissionDeniedError,
    404 => TypeSafe.NotFoundError,
    422 => TypeSafe.UnprocessableEntityError,
    429 => TypeSafe.RateLimitError
  }

  @doc """
  Build the exception struct that matches an HTTP error `status`.

  `headers` is a map of lowercased header names to string values. `endpoint` is a human-readable
  `"METHOD URL"` (without credentials) or `nil`.
  """
  @spec api_error(pos_integer(), term(), %{optional(String.t()) => String.t()}, String.t() | nil) ::
          TypeSafe.APIError.t()
  def api_error(status, body, headers, endpoint \\ nil) do
    module = module_for_status(status)

    # A found-but-empty message (e.g. `{"error": ""}`) is treated as no message: fall back to the body.
    message =
      case extract_message(body) do
        blank when blank in [nil, ""] -> fallback_message(body)
        found -> found
      end

    request_id = Map.get(headers, "x-typesafe-request-id")

    fields = [
      status: status,
      body: body,
      headers: headers,
      request_id: request_id,
      endpoint: endpoint,
      message: format(status, message, endpoint, request_id)
    ]

    fields =
      if module == TypeSafe.RateLimitError do
        Keyword.put(fields, :retry_after_ms, TypeSafe.Error.RetryAfter.parse(headers))
      else
        fields
      end

    struct(module, fields)
  end

  defp module_for_status(status) when status >= 500, do: TypeSafe.InternalServerError
  defp module_for_status(status), do: Map.get(@status_modules, status, TypeSafe.APIError)

  @doc false
  def format(status, message, endpoint, request_id) do
    base = if message in [nil, ""], do: "#{status}", else: "#{status} #{message}"
    base = if endpoint, do: "#{endpoint}: #{base}", else: base
    if request_id, do: base <> " (request_id=#{request_id})", else: base
  end

  @max_body_length 200

  defp fallback_message(nil), do: "status code (no body)"

  defp fallback_message(body) do
    raw = if is_binary(body), do: body, else: Jason.encode!(body)

    if String.length(raw) > @max_body_length do
      String.slice(raw, 0, @max_body_length) <> "…"
    else
      raw
    end
  end

  @doc """
  Extract a human-readable message from a decoded error `body`, mirroring the shapes the API uses.

  Returns `nil` when no message can be found.
  """
  @spec extract_message(term()) :: String.t() | nil
  def extract_message(body) when is_binary(body), do: if(body == "", do: nil, else: body)

  def extract_message(%{} = body) do
    cond do
      is_binary(body["error"]) -> body["error"]
      is_map(body["error"]) and is_binary(body["error"]["message"]) -> body["error"]["message"]
      is_binary(body["message"]) -> body["message"]
      is_binary(body["detail"]) -> body["detail"]
      is_map(body["detail"]) and is_binary(body["detail"]["message"]) -> body["detail"]["message"]
      is_list(body["detail"]) -> extract_validation_detail(body["detail"])
      true -> nil
    end
  end

  def extract_message(_), do: nil

  defp extract_validation_detail(entries) do
    parts =
      for entry <- entries, is_map(entry), is_binary(entry["msg"]) do
        case entry["loc"] do
          loc when is_list(loc) ->
            path = loc |> Enum.reject(&(&1 == "body")) |> Enum.join(".")
            if path == "", do: entry["msg"], else: "#{path}: #{entry["msg"]}"

          _ ->
            entry["msg"]
        end
      end

    case parts do
      [] -> nil
      parts -> Enum.join(parts, "; ")
    end
  end
end

defmodule TypeSafe.Error.RetryAfter do
  @moduledoc false
  # Parses `retry-after-ms` and `retry-after` headers into a millisecond delay, or `nil`.

  @spec parse(%{optional(String.t()) => String.t()}) :: number() | nil
  def parse(headers) do
    parse_ms(Map.get(headers, "retry-after-ms")) ||
      parse_seconds(Map.get(headers, "retry-after"))
  end

  defp parse_ms(nil), do: nil

  defp parse_ms(raw) do
    case Float.parse(String.trim(raw)) do
      {value, ""} when value >= 0 -> value
      _ -> nil
    end
  end

  defp parse_seconds(nil), do: nil

  defp parse_seconds(raw) do
    case Float.parse(String.trim(raw)) do
      {value, ""} when value >= 0 -> value * 1000
      # HTTP-date form is accepted by the server but not honored client-side here.
      _ -> nil
    end
  end
end

defmodule TypeSafe.ConfigError do
  @moduledoc """
  Raised when SDK configuration or input is invalid before any request is sent.

  Examples: a missing or malformed API key, an empty `questions` map, a score question without
  criteria, or a request body that cannot be encoded as JSON.
  """
  defexception [:message]
  @type t :: %__MODULE__{message: String.t()}
end

defmodule TypeSafe.ConnectionError do
  @moduledoc "A request failed without producing an HTTP response (DNS, TCP, TLS, or read errors)."
  defexception [:message, :reason]
  @type t :: %__MODULE__{message: String.t(), reason: term()}
end

defmodule TypeSafe.TimeoutError do
  @moduledoc "A request exceeded its configured timeout."
  defexception [:message, :timeout]
  @type t :: %__MODULE__{message: String.t(), timeout: number() | nil}
end

defmodule TypeSafe.ResponseValidationError do
  @moduledoc """
  A successful HTTP response whose body was missing or structurally invalid required data.

  `:field_path` names the first offending field, such as `"answers.tone.confidence"`.
  """
  defexception [:message, :status, :body, :headers, :request_id, :endpoint, :field_path]

  @type t :: %__MODULE__{
          message: String.t(),
          status: pos_integer(),
          body: term(),
          headers: %{optional(String.t()) => String.t()},
          request_id: String.t() | nil,
          endpoint: String.t() | nil,
          field_path: String.t()
        }
end

# The per-status HTTP error structs. They intentionally share the same shape so that callers can
# pattern-match on the fields of any of them, and pick the concrete struct they care about.
for module <- [
      TypeSafe.APIError,
      TypeSafe.BadRequestError,
      TypeSafe.AuthenticationError,
      TypeSafe.PermissionDeniedError,
      TypeSafe.NotFoundError,
      TypeSafe.UnprocessableEntityError,
      TypeSafe.InternalServerError
    ] do
  defmodule module do
    @moduledoc """
    An unsuccessful HTTP response from the TypeSafe API.

    Fields:

      * `:status` — HTTP status code.
      * `:body` — decoded JSON error body, plain text, or `nil` for an empty body.
      * `:headers` — response headers as a map of lowercased names to values.
      * `:request_id` — the `x-typesafe-request-id` header, or `nil`.
      * `:endpoint` — `"METHOD URL"` without credentials, or `nil`.
      * `:message` — a formatted, human-readable summary.
    """
    defexception [:status, :body, :headers, :request_id, :endpoint, :message]

    @type t :: %__MODULE__{
            status: pos_integer(),
            body: term(),
            headers: %{optional(String.t()) => String.t()},
            request_id: String.t() | nil,
            endpoint: String.t() | nil,
            message: String.t()
          }
  end
end

defmodule TypeSafe.RateLimitError do
  @moduledoc """
  The rate limit was exceeded (HTTP 429).

  In addition to the shared HTTP error fields, `:retry_after_ms` holds the server's requested wait
  in milliseconds parsed from the `retry-after`/`retry-after-ms` headers, or `nil` when absent.
  """
  defexception [:status, :body, :headers, :request_id, :endpoint, :message, :retry_after_ms]

  @type t :: %__MODULE__{
          status: pos_integer(),
          body: term(),
          headers: %{optional(String.t()) => String.t()},
          request_id: String.t() | nil,
          endpoint: String.t() | nil,
          message: String.t(),
          retry_after_ms: number() | nil
        }
end
