defmodule TypeSafe do
  @moduledoc """
  Elixir client for the [TypeSafe AI](https://typesafe.ai) API.

  ## Quickstart

  Set `TYPESAFE_API_KEY` in your environment, build a client, and ask questions about some state:

      client = TypeSafe.new()

      {:ok, response} =
        TypeSafe.system_one(client, "I was charged twice. Please fix this ASAP.", %{
          "category" =>
            TypeSafe.Question.choice(
              instructions: "What is this ticket about?",
              criteria: %{"billing" => nil, "technical" => nil, "other" => nil}
            )
        })

      response.choices["category"].choice
      #=> "billing"

  A client is a plain immutable value — build it once and share it. Every request returns
  `{:ok, result}` or `{:error, exception}`; the `!` variants (`system_one!/4`, `list_models!/2`)
  return the result or raise. See `TypeSafe.Error` for the exception structs.

  ## Questions and answers

  Build questions with `TypeSafe.Question.noul/1`, `TypeSafe.Question.choice/1`, and
  `TypeSafe.Question.score/1`. Answers come back as `TypeSafe.Answer.Noul`, `TypeSafe.Answer.Choice`,
  and `TypeSafe.Answer.Score` structs, grouped on the response by `:nouls`, `:choices`, and `:scores`.
  """

  @version Mix.Project.config()[:version]
  @sdk_name "typesafe-sdk"

  @system_one_path "/v1/systemone"
  @models_path "/v1/models"

  alias TypeSafe.{Client, HTTP, Question, Response}

  @typedoc "State to evaluate: text, a JSON object (map), or a JSON array (list)."
  @type state :: String.t() | map() | list()

  @doc """
  Build a `TypeSafe.Client`.

  Explicit options take precedence over environment variables.

  ## Options

    * `:api_key` — API key. Defaults to the `TYPESAFE_API_KEY` environment variable. Required.
    * `:base_url` — API root. Defaults to `TYPESAFE_BASE_URL` or `https://api.typesafe.ai`.
    * `:model` — default model. Defaults to `TYPESAFE_DEFAULT_MODEL` or `jev-latest`.
    * `:timeout` — per-request receive timeout in milliseconds. Defaults to `10_000`.
    * `:max_retries` — retries after the initial attempt. Defaults to `2`; use `0` to disable.
    * `:retry`, `:retry_delay` — overrides passed through to `Req` (see `Req` retry docs).
    * `:headers` — extra default headers (a map).
    * `:req_options` — a keyword list merged into `Req.new/1` (escape hatch for e.g. `:connect_options`).
    * `:plug` — a `Plug`/`Req.Test` stub used instead of the network, for tests.

  Raises `TypeSafe.ConfigError` when the API key is missing or invalid.
  """
  @spec new(keyword()) :: Client.t()
  def new(opts \\ []), do: Client.new(opts)

  @doc """
  Answer named `questions` about `state`.

  `questions` is a non-empty map of names (any term you choose, typically a string) to questions built
  with `TypeSafe.Question`, or raw maps carrying a `"type"` key. The names key the answers in the
  response.

  ## Options

    * `:model` — model override for this call; defaults to the client's model.
    * `:timeout` — per-call receive timeout in milliseconds.
    * `:headers` — extra headers for this call (a map).
    * `:extra_body` — a map with string keys, shallow-merged over the request body (`"state"`,
      `"model"`, `"questions"`); a colliding key overrides the default.

  Returns `{:ok, %TypeSafe.Response.SystemOne{}}` or `{:error, exception}`.

  ## Examples

      {:ok, response} =
        TypeSafe.system_one(client, "I was charged twice. Please help.", %{
          "billing" => TypeSafe.Question.noul(instructions: "Is this about billing?"),
          "tone" =>
            TypeSafe.Question.choice(
              instructions: "What is the tone?",
              criteria: %{"calm" => nil, "angry" => nil}
            )
        })

      response.nouls["billing"].noul     #=> 0.98
      response.choices["tone"].choice    #=> "angry"
  """
  @spec system_one(Client.t(), state(), map(), keyword()) ::
          {:ok, Response.SystemOne.t()} | {:error, TypeSafe.Error.t()}
  def system_one(%Client{} = client, state, questions, opts \\ []) when is_map(questions) do
    with {:ok, questions} <- Question.normalize(questions) do
      body =
        %{
          "state" => state,
          "model" => opts[:model] || client.config.default_model,
          "questions" => questions
        }
        |> merge_extra_body(opts[:extra_body])

      req_opts = [json: body] |> put_headers(opts[:headers]) |> put_timeout(opts[:timeout])
      HTTP.request(client, :post, @system_one_path, req_opts, &Response.parse_system_one/2)
    end
  end

  @doc "Like `system_one/4`, but returns the response or raises the exception."
  @spec system_one!(Client.t(), state(), map(), keyword()) :: Response.SystemOne.t()
  def system_one!(client, state, questions, opts \\ []) do
    unwrap!(system_one(client, state, questions, opts))
  end

  @doc """
  List the models available to the account.

  ## Options

    * `:timeout` — per-call receive timeout in milliseconds.
    * `:headers` — extra headers for this call (a map).

  Returns `{:ok, %TypeSafe.Response.ListModels{}}` or `{:error, exception}`.
  """
  @spec list_models(Client.t(), keyword()) ::
          {:ok, Response.ListModels.t()} | {:error, TypeSafe.Error.t()}
  def list_models(%Client{} = client, opts \\ []) do
    req_opts = [] |> put_headers(opts[:headers]) |> put_timeout(opts[:timeout])
    HTTP.request(client, :get, @models_path, req_opts, &Response.parse_list_models/2)
  end

  @doc "Like `list_models/2`, but returns the response or raises the exception."
  @spec list_models!(Client.t(), keyword()) :: Response.ListModels.t()
  def list_models!(client, opts \\ []), do: unwrap!(list_models(client, opts))

  @doc "The SDK version string."
  @spec version() :: String.t()
  def version, do: @version

  @doc false
  def sdk_name, do: @sdk_name

  defp merge_extra_body(body, nil), do: body
  defp merge_extra_body(body, extra) when is_map(extra), do: Map.merge(body, extra)

  defp put_headers(opts, nil), do: opts
  defp put_headers(opts, headers), do: Keyword.put(opts, :headers, headers)

  defp put_timeout(opts, nil), do: opts
  defp put_timeout(opts, timeout), do: Keyword.put(opts, :receive_timeout, timeout)

  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:error, exception}), do: raise(exception)
end
