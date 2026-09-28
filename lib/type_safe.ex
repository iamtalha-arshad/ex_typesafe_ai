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

  ## Application-level clients

  Instead of threading a client value through your code, you can start one under your supervision
  tree and refer to it by name:

      children = [
        {TypeSafe, name: MyApp.TypeSafe, api_key: System.fetch_env!("TYPESAFE_API_KEY")}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  Then pass the name anywhere a client is accepted:

      TypeSafe.system_one(MyApp.TypeSafe, state, questions)

  The client is built once at startup (a bad key or option fails the boot loudly) and read
  lock-free on every call. `TypeSafe.client/1` returns the underlying `TypeSafe.Client` if you need
  the value itself.

  ## Questions and answers

  Build questions with `TypeSafe.Question.noul/1`, `TypeSafe.Question.choice/1`, and
  `TypeSafe.Question.score/1`. Answers come back as `TypeSafe.Answer.Noul`, `TypeSafe.Answer.Choice`,
  and `TypeSafe.Answer.Score` structs, grouped on the response by `:nouls`, `:choices`, and `:scores`.
  """

  @version Mix.Project.config()[:version]
  @sdk_name "typesafe-sdk"

  @system_one_path "/v1/systemone"
  @models_path "/v1/models"

  alias TypeSafe.{Client, HTTP, Question, Response, Server}

  @typedoc "State to evaluate: text, a JSON object (map), or a JSON array (list)."
  @type state :: String.t() | map() | list()

  @typedoc "A built client value, or the atom name of one started under a supervision tree."
  @type client :: Client.t() | atom()

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
  Child spec for starting an application-level client under a supervision tree.

  Requires a `:name` (a non-nil atom); the remaining options are the same as `new/1`. The child is
  keyed by its name, so several named clients can live under one supervisor. Referenced implicitly
  when you place `{TypeSafe, opts}` in a supervisor's child list.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts), do: Server.child_spec(opts)

  @doc """
  Start an application-level client and register it under `opts[:name]`.

  Usually invoked for you via `{TypeSafe, opts}` in a supervision tree rather than called directly.
  Raises `ArgumentError` when `:name` is missing and `TypeSafe.ConfigError` on invalid configuration.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: Server.start_link(opts)

  @doc """
  Return the `TypeSafe.Client` registered under `name`.

  Raises `TypeSafe.ConfigError` if no client is registered — usually because `{TypeSafe, name: name}`
  is not in the supervision tree, or has not started yet.
  """
  @spec client(atom()) :: Client.t()
  def client(name) when is_atom(name) do
    case Server.fetch(name) do
      {:ok, client} ->
        client

      :error ->
        raise TypeSafe.ConfigError,
          message:
            "No TypeSafe client is registered under #{inspect(name)}. " <>
              "Add {TypeSafe, name: #{inspect(name)}, api_key: ...} to your supervision tree."
    end
  end

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
  @spec system_one(client(), state(), map(), keyword()) ::
          {:ok, Response.SystemOne.t()} | {:error, TypeSafe.Error.t()}
  def system_one(client, state, questions, opts \\ []) when is_map(questions) do
    client = resolve(client)

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
  @spec system_one!(client(), state(), map(), keyword()) :: Response.SystemOne.t()
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
  @spec list_models(client(), keyword()) ::
          {:ok, Response.ListModels.t()} | {:error, TypeSafe.Error.t()}
  def list_models(client, opts \\ []) do
    client = resolve(client)
    req_opts = [] |> put_headers(opts[:headers]) |> put_timeout(opts[:timeout])
    HTTP.request(client, :get, @models_path, req_opts, &Response.parse_list_models/2)
  end

  @doc "Like `list_models/2`, but returns the response or raises the exception."
  @spec list_models!(client(), keyword()) :: Response.ListModels.t()
  def list_models!(client, opts \\ []), do: unwrap!(list_models(client, opts))

  @doc "The SDK version string."
  @spec version() :: String.t()
  def version, do: @version

  @doc false
  def sdk_name, do: @sdk_name

  defp resolve(%Client{} = client), do: client
  defp resolve(name) when is_atom(name), do: client(name)

  defp merge_extra_body(body, nil), do: body
  defp merge_extra_body(body, extra) when is_map(extra), do: Map.merge(body, extra)

  defp put_headers(opts, nil), do: opts
  defp put_headers(opts, headers), do: Keyword.put(opts, :headers, headers)

  defp put_timeout(opts, nil), do: opts
  defp put_timeout(opts, timeout), do: Keyword.put(opts, :receive_timeout, timeout)

  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:error, exception}), do: raise(exception)
end
