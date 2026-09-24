defmodule TypeSafe.Config do
  @moduledoc """
  Resolves and validates client configuration from explicit options and environment variables.

  Explicit options always win over environment variables. Empty or whitespace-only environment
  values are ignored and fall back to the built-in defaults.
  """

  @api_key_env "TYPESAFE_API_KEY"
  @base_url_env "TYPESAFE_BASE_URL"
  @default_model_env "TYPESAFE_DEFAULT_MODEL"

  @default_base_url "https://api.typesafe.ai"
  @default_model "jev-latest"
  @default_timeout 10_000

  @typedoc "Resolved, validated configuration."
  @type t :: %__MODULE__{
          api_key: String.t(),
          base_url: String.t(),
          default_model: String.t(),
          timeout: pos_integer(),
          headers: %{optional(String.t()) => String.t()}
        }

  @enforce_keys [:api_key, :base_url, :default_model, :timeout, :headers]
  defstruct [:api_key, :base_url, :default_model, :timeout, :headers]

  @doc "The environment variable names read during resolution."
  @spec env_vars() :: %{api_key: String.t(), base_url: String.t(), default_model: String.t()}
  def env_vars,
    do: %{api_key: @api_key_env, base_url: @base_url_env, default_model: @default_model_env}

  @doc """
  Resolve configuration, raising `TypeSafe.ConfigError` when the API key or timeout is invalid.

  Recognized options: `:api_key`, `:base_url`, `:model`, `:timeout` (milliseconds), and `:headers`.
  """
  @spec resolve!(keyword()) :: t()
  def resolve!(opts) do
    %__MODULE__{
      api_key: resolve_api_key!(opts[:api_key]),
      base_url:
        opts
        |> resolve_string(:base_url, @base_url_env, @default_base_url)
        |> String.trim_trailing("/"),
      default_model: resolve_string(opts, :model, @default_model_env, @default_model),
      timeout: resolve_timeout!(Keyword.get(opts, :timeout, @default_timeout)),
      headers: normalize_headers(Keyword.get(opts, :headers, %{}))
    }
  end

  defp resolve_string(opts, key, env, default) do
    case Keyword.get(opts, key) do
      value when is_binary(value) -> value
      _ -> env |> System.get_env("") |> String.trim() |> fallback(default)
    end
  end

  defp fallback("", default), do: default
  defp fallback(value, _default), do: value

  defp resolve_api_key!(explicit) do
    key =
      case explicit do
        value when is_binary(value) -> String.trim(value)
        _ -> @api_key_env |> System.get_env("") |> String.trim()
      end

    cond do
      key == "" ->
        raise TypeSafe.ConfigError,
          message:
            "No API key was provided. Pass :api_key or set the #{@api_key_env} environment variable."

      not valid_api_key?(key) ->
        raise TypeSafe.ConfigError,
          message: "API key must contain only printable ASCII characters without whitespace."

      true ->
        key
    end
  end

  # Printable ASCII (33..126) excludes control characters and whitespace, mirroring the other SDKs.
  defp valid_api_key?(key), do: key |> String.to_charlist() |> Enum.all?(&(&1 in 33..126))

  defp resolve_timeout!(timeout) when is_integer(timeout) and timeout > 0, do: timeout

  defp resolve_timeout!(_timeout) do
    raise TypeSafe.ConfigError,
      message: "timeout must be a positive integer number of milliseconds."
  end

  defp normalize_headers(headers) do
    Map.new(headers, fn {name, value} ->
      {name |> to_string() |> String.downcase(), to_string(value)}
    end)
  end
end
