# ex_typesafe

Idiomatic Elixir client for the [TypeSafe AI](https://typesafe.ai) API.

> **Unofficial.** This is a community-maintained client and is not affiliated with, sponsored by, or
> endorsed by TypeSafe AI. "TypeSafe" and related marks belong to their respective owner.

## Installation

Add `:ex_typesafe` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ex_typesafe, "~> 0.1"}
  ]
end
```

## Quickstart

Set `TYPESAFE_API_KEY` in your environment, build a client, and ask questions about some state:

```elixir
alias TypeSafe.Question

client = TypeSafe.new()

{:ok, response} =
  TypeSafe.system_one(client, "I was charged twice. Please fix this ASAP.", %{
    "category" =>
      Question.choice(
        instructions: "What is this ticket about?",
        criteria: %{"billing" => nil, "technical" => nil, "other" => nil}
      )
  })

response.choices["category"].choice
#=> "billing"
```

Learn what TypeSafe is, what it can do, and how to use it in the
[TypeSafe docs](https://docs.typesafe.ai/).

## Usage

### Building a client

`TypeSafe.new/1` returns an immutable `TypeSafe.Client` value — build it once and share it across
processes. Explicit options take precedence over environment variables.

```elixir
client =
  TypeSafe.new(
    api_key: System.fetch_env!("TYPESAFE_API_KEY"),  # or TYPESAFE_API_KEY in the environment
    base_url: "https://api.typesafe.ai",             # or TYPESAFE_BASE_URL
    model: "jev-latest",                             # or TYPESAFE_DEFAULT_MODEL
    timeout: 10_000,                                 # per-request receive timeout, ms
    max_retries: 2                                   # retries after the first attempt
  )
```

### Questions

Build questions with the three primitives. Each is a struct with a constructor:

```elixir
alias TypeSafe.Question

# yes/no
Question.noul(instructions: "Is this message spam?")

# choose one named label (criteria required)
Question.choice(
  instructions: "What is the tone?",
  criteria: %{"calm" => "polite", "angry" => "hostile"}
)

# rate against an ordered rubric (criteria required, non-empty)
Question.score(
  instructions: "How urgent is this?",
  criteria: ["can wait", "this week", "today"]
)
```

You can also pass a raw map with a `"type"` key as an escape hatch for fields the API supports before
this SDK models them.

### Answers

Every request returns `{:ok, result}` or `{:error, exception}`. On success you get a
`TypeSafe.Response.SystemOne` with answers keyed by your question names and grouped by type:

```elixir
{:ok, response} =
  TypeSafe.system_one(client, "I was charged twice. Please help.", %{
    "billing" => Question.noul(instructions: "Is this about billing?"),
    "tone" => Question.choice(instructions: "What is the tone?", criteria: %{"calm" => nil, "angry" => nil}),
    "urgency" => Question.score(instructions: "How urgent?", criteria: ["low", "high"])
  })

response.nouls["billing"].noul       # e.g. 0.98
response.choices["tone"].choice      # e.g. "angry"
response.scores["urgency"].score     # e.g. 0.8
response.usage.input_tokens          # token counts
response.request_id                  # x-typesafe-request-id
```

Answer structs: `TypeSafe.Answer.Noul`, `TypeSafe.Answer.Choice`, `TypeSafe.Answer.Score`.

### Listing models

```elixir
{:ok, %TypeSafe.Response.ListModels{models: models}} = TypeSafe.list_models(client)
Enum.map(models, & &1.name)
```

### Errors

Errors are returned in `{:error, exception}` tuples; the `!` variants (`TypeSafe.system_one!/4`,
`TypeSafe.list_models!/2`) raise them instead.

```elixir
case TypeSafe.system_one(client, state, questions) do
  {:ok, response} -> handle(response)
  {:error, %TypeSafe.RateLimitError{retry_after_ms: ms}} -> backoff(ms)
  {:error, %TypeSafe.AuthenticationError{}} -> refresh_key()
  {:error, error} -> Logger.error(Exception.message(error))
end
```

See `TypeSafe.Error` for the full list, including per-status structs (`TypeSafe.BadRequestError`,
`TypeSafe.NotFoundError`, …), `TypeSafe.ConnectionError`, `TypeSafe.TimeoutError`,
`TypeSafe.ResponseValidationError`, and `TypeSafe.ConfigError`.

### Retries

Transient failures (HTTP 408, 429, 5xx, and transport errors) are retried automatically with
exponential backoff, honoring `Retry-After`. Tune with `:max_retries` (0 disables), or pass your own
`:retry` / `:retry_delay` functions straight through to [`Req`](https://hexdocs.pm/req).

### Testing against the SDK

The client accepts a `:plug` option, so you can stub HTTP in tests with
[`Req.Test`](https://hexdocs.pm/req/Req.Test.html) — no network required:

```elixir
Req.Test.stub(MyStub, fn conn ->
  Req.Test.json(conn, %{
    "model" => "jev-latest",
    "usage" => %{"input_tokens" => 1, "output_tokens" => 1},
    "answers" => %{"billing" => %{"type" => "noul", "noul" => 0.98}}
  })
end)

client = TypeSafe.new(api_key: "test", plug: {Req.Test, MyStub})
```

## Documentation

Learn more in the [TypeSafe SDK docs](https://docs.typesafe.ai/). API reference for this library is
generated with [ExDoc](https://hexdocs.pm/ex_doc) (`mix docs`).

## License

MIT
