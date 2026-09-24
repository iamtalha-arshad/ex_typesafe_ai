defmodule TypeSafe.Response.Usage do
  @moduledoc "Token counts for a request. Either field may be `nil` when the API does not report it."
  defstruct input_tokens: nil, output_tokens: nil

  @type t :: %__MODULE__{input_tokens: integer() | nil, output_tokens: integer() | nil}
end

defmodule TypeSafe.Response.ModelMetadata do
  @moduledoc "Metadata describing a single available model."
  @enforce_keys [:name, :description, :release_date]
  defstruct [:name, :description, :release_date]

  @type t :: %__MODULE__{name: String.t(), description: String.t(), release_date: String.t()}
end

defmodule TypeSafe.Response.SystemOne do
  @moduledoc """
  The result of a `TypeSafe.system_one/4` call.

    * `:model` — the model that answered the request.
    * `:usage` — a `TypeSafe.Response.Usage` with token counts.
    * `:answers` — every answer keyed by question name.
    * `:nouls` / `:choices` / `:scores` — the answers grouped by type, each keyed by question name.
    * `:request_id` — the `x-typesafe-request-id` header, or `nil`.
    * `:raw` — the underlying `Req.Response`.
  """
  @enforce_keys [:model, :usage]
  defstruct [
    :model,
    :usage,
    :request_id,
    :raw,
    answers: %{},
    nouls: %{},
    choices: %{},
    scores: %{}
  ]

  @type t :: %__MODULE__{
          model: String.t(),
          usage: TypeSafe.Response.Usage.t(),
          answers: %{optional(String.t()) => TypeSafe.Answer.t()},
          nouls: %{optional(String.t()) => TypeSafe.Answer.Noul.t()},
          choices: %{optional(String.t()) => TypeSafe.Answer.Choice.t()},
          scores: %{optional(String.t()) => TypeSafe.Answer.Score.t()},
          request_id: String.t() | nil,
          raw: term()
        }
end

defmodule TypeSafe.Response.ListModels do
  @moduledoc """
  The models available to the account.

    * `:models` — a list of `TypeSafe.Response.ModelMetadata`.
    * `:request_id` — the `x-typesafe-request-id` header, or `nil`.
    * `:raw` — the underlying `Req.Response`.
  """
  @enforce_keys [:models]
  defstruct [:models, :request_id, :raw]

  @type t :: %__MODULE__{
          models: [TypeSafe.Response.ModelMetadata.t()],
          request_id: String.t() | nil,
          raw: term()
        }
end

defmodule TypeSafe.Response do
  @moduledoc """
  Decoding of successful API responses into their public structs.

  This module is used internally by `TypeSafe`; you normally interact with the returned
  `TypeSafe.Response.SystemOne` and `TypeSafe.Response.ListModels` structs rather than calling it
  directly.
  """

  alias TypeSafe.Response.{ListModels, ModelMetadata, SystemOne, Usage}

  @typedoc """
  HTTP metadata carried alongside a decoded body.

    * `:status` — response status code.
    * `:headers` — map of lowercased header names to values.
    * `:request_id` — the `x-typesafe-request-id` header, or `nil`.
    * `:endpoint` — `"METHOD URL"` without credentials, or `nil`.
    * `:raw` — the underlying `Req.Response`.
  """
  @type meta :: %{
          status: pos_integer(),
          headers: %{optional(String.t()) => String.t()},
          request_id: String.t() | nil,
          endpoint: String.t() | nil,
          raw: term()
        }

  @doc "Decode a `POST /v1/systemone` body into a `TypeSafe.Response.SystemOne`."
  @spec parse_system_one(term(), meta()) ::
          {:ok, SystemOne.t()} | {:error, TypeSafe.ResponseValidationError.t()}
  def parse_system_one(decoded, meta) when is_map(decoded) do
    with {:ok, model} <- require_string(decoded, "model"),
         {:ok, usage} <- parse_usage(decoded),
         {:ok, answers} <- parse_answers(Map.get(decoded, "answers", %{})) do
      grouped = Enum.group_by(answers, fn {_name, answer} -> answer.type end)

      {:ok,
       %SystemOne{
         model: model,
         usage: usage,
         answers: answers,
         nouls: by_name(grouped, "noul"),
         choices: by_name(grouped, "choice"),
         scores: by_name(grouped, "score"),
         request_id: meta.request_id,
         raw: meta.raw
       }}
    else
      {:error, path} -> {:error, validation_error(meta, path)}
    end
  end

  def parse_system_one(_decoded, meta), do: {:error, validation_error(meta, "")}

  @doc "Decode a `GET /v1/models` body into a `TypeSafe.Response.ListModels`."
  @spec parse_list_models(term(), meta()) ::
          {:ok, ListModels.t()} | {:error, TypeSafe.ResponseValidationError.t()}
  def parse_list_models(%{"models" => models}, meta) when is_list(models) do
    models
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {model, index}, {:ok, acc} ->
      case parse_model(model) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, field} -> {:halt, {:error, "models[#{index}].#{field}"}}
      end
    end)
    |> case do
      {:ok, reversed} ->
        {:ok,
         %ListModels{models: Enum.reverse(reversed), request_id: meta.request_id, raw: meta.raw}}

      {:error, path} ->
        {:error, validation_error(meta, path)}
    end
  end

  def parse_list_models(_decoded, meta), do: {:error, validation_error(meta, "models")}

  defp parse_model(%{} = model) do
    with {:ok, name} <- require_string(model, "name"),
         {:ok, description} <- require_string(model, "description"),
         {:ok, release_date} <- require_string(model, "release_date") do
      {:ok, %ModelMetadata{name: name, description: description, release_date: release_date}}
    end
  end

  defp parse_model(_), do: {:error, "name"}

  defp parse_usage(decoded) do
    case Map.get(decoded, "usage") do
      %{} = usage ->
        {:ok,
         %Usage{
           input_tokens: optional_int(usage, "input_tokens"),
           output_tokens: optional_int(usage, "output_tokens")
         }}

      _ ->
        {:error, "usage"}
    end
  end

  defp parse_answers(answers) when is_map(answers) do
    Enum.reduce_while(answers, {:ok, %{}}, fn {name, raw}, {:ok, acc} ->
      case TypeSafe.Answer.parse(name, raw) do
        {:ok, answer} -> {:cont, {:ok, Map.put(acc, name, answer)}}
        :skip -> {:cont, {:ok, acc}}
        {:error, field} -> {:halt, {:error, "answers.#{name}.#{field}"}}
      end
    end)
  end

  defp parse_answers(_), do: {:error, "answers"}

  defp by_name(grouped, type) do
    grouped |> Map.get(type, []) |> Map.new()
  end

  defp require_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> {:error, key}
    end
  end

  defp optional_int(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      _ -> nil
    end
  end

  defp validation_error(meta, path) do
    message =
      TypeSafe.Error.format(
        meta.status,
        "Invalid response data at '#{path}'.",
        meta.endpoint,
        meta.request_id
      )

    %TypeSafe.ResponseValidationError{
      message: message,
      status: meta.status,
      body: nil_body(meta),
      headers: meta.headers,
      request_id: meta.request_id,
      endpoint: meta.endpoint,
      field_path: path
    }
  end

  defp nil_body(%{raw: %{body: body}}), do: body
  defp nil_body(_), do: nil
end
