defmodule TypeSafe.Question.Noul do
  @moduledoc """
  A yes/no question. Build with `TypeSafe.Question.noul/1`.
  """
  @enforce_keys []
  defstruct type: "noul", instructions: nil, criteria: nil

  @type t :: %__MODULE__{
          type: String.t(),
          instructions: TypeSafe.Question.content() | nil,
          criteria: map() | nil
        }
end

defmodule TypeSafe.Question.Choice do
  @moduledoc """
  A question that selects one of several named labels. Build with `TypeSafe.Question.choice/1`.
  """
  @enforce_keys [:criteria]
  defstruct type: "choice", instructions: nil, criteria: %{}

  @type t :: %__MODULE__{
          type: String.t(),
          instructions: TypeSafe.Question.content() | nil,
          criteria: %{optional(String.t()) => TypeSafe.Question.content() | nil}
        }
end

defmodule TypeSafe.Question.Score do
  @moduledoc """
  A question that rates state against an ordered rubric. Build with `TypeSafe.Question.score/1`.
  """
  @enforce_keys [:criteria]
  defstruct type: "score", instructions: nil, criteria: []

  @type t :: %__MODULE__{
          type: String.t(),
          instructions: TypeSafe.Question.content() | nil,
          criteria: [TypeSafe.Question.content()]
        }
end

defmodule TypeSafe.Question do
  @moduledoc """
  Questions asked about a piece of `state` in a `TypeSafe.system_one/4` request.

  There are three question primitives, each with its own struct and a constructor here:

    * `noul/1` — a yes/no question. See the [noul primitive](https://docs.typesafe.ai/primitives/noul).
    * `choice/1` — selects one of several named labels. See the
      [choice primitive](https://docs.typesafe.ai/primitives/choice).
    * `score/1` — rates the state against an ordered rubric. See the
      [score primitive](https://docs.typesafe.ai/primitives/score).

  Each accepts a keyword list. `:instructions` is always optional and may be a string, a map, or a
  list. `choice/1` and `score/1` require `:criteria`.

      iex> TypeSafe.Question.noul(instructions: "Is this message spam?")
      %TypeSafe.Question.Noul{type: "noul", instructions: "Is this message spam?", criteria: nil}

      iex> TypeSafe.Question.choice(instructions: "What is the tone?", criteria: %{"angry" => nil})
      %TypeSafe.Question.Choice{type: "choice", instructions: "What is the tone?", criteria: %{"angry" => nil}}

      iex> TypeSafe.Question.score(instructions: "How urgent?", criteria: ["low", "high"])
      %TypeSafe.Question.Score{type: "score", instructions: "How urgent?", criteria: ["low", "high"]}

  A question may also be supplied as a raw map with a `"type"` key (or `:type`) as an escape hatch for
  fields the API supports before this SDK models them; such maps are passed through untouched and
  validated by the API.
  """

  alias TypeSafe.Question.{Choice, Noul, Score}

  @typedoc "Text, a JSON object, or a JSON array."
  @type content :: String.t() | map() | list()

  @typedoc "A question struct or a raw map passed straight through to the API."
  @type t :: Noul.t() | Choice.t() | Score.t() | map()

  @doc """
  Build a yes/no (`noul`) question.

  Options:

    * `:instructions` — the question or statement to evaluate; optional.
    * `:criteria` — an optional map describing the yes/no outcomes, e.g.
      `%{true: "unsolicited ad", false: "a real conversation"}`.
  """
  @spec noul(keyword()) :: Noul.t()
  def noul(opts \\ []) do
    %Noul{instructions: Keyword.get(opts, :instructions), criteria: Keyword.get(opts, :criteria)}
  end

  @doc """
  Build a `choice` question that selects one of the labels in `:criteria`.

  Options:

    * `:criteria` (required) — a map of label => description (or `nil` for an undescribed label).
    * `:instructions` — what to decide; optional.

  Raises `TypeSafe.ConfigError` when `:criteria` is missing.
  """
  @spec choice(keyword()) :: Choice.t()
  def choice(opts) do
    criteria = require_criteria!(opts, "choice")
    %Choice{instructions: Keyword.get(opts, :instructions), criteria: criteria}
  end

  @doc """
  Build a `score` question that rates the state against the ordered rubric in `:criteria`.

  Options:

    * `:criteria` (required) — a non-empty, ordered list of level descriptions; the first is score 0.
    * `:instructions` — what to rate; optional.

  Raises `TypeSafe.ConfigError` when `:criteria` is missing or empty.
  """
  @spec score(keyword()) :: Score.t()
  def score(opts) do
    criteria = require_criteria!(opts, "score")

    if criteria == [] do
      raise TypeSafe.ConfigError, message: "Score question criteria must not be empty."
    end

    %Score{instructions: Keyword.get(opts, :instructions), criteria: criteria}
  end

  defp require_criteria!(opts, type) do
    case Keyword.fetch(opts, :criteria) do
      {:ok, criteria} -> criteria
      :error -> raise TypeSafe.ConfigError, message: ~s(#{type} question requires :criteria.)
    end
  end

  @doc """
  Validate a `questions` map before it is sent.

  Returns `{:ok, questions}` unchanged, or `{:error, %TypeSafe.ConfigError{}}` when the map is empty
  or a score question is missing/has empty criteria. Struct questions built with the constructors are
  always valid; raw maps are only lightly checked, leaving full validation to the API.
  """
  @spec normalize(map()) :: {:ok, map()} | {:error, TypeSafe.ConfigError.t()}
  def normalize(questions) when questions == %{} do
    {:error, %TypeSafe.ConfigError{message: "At least one question is required."}}
  end

  def normalize(questions) when is_map(questions) do
    Enum.reduce_while(questions, {:ok, questions}, fn {name, question}, acc ->
      case validate_question(name, question) do
        :ok -> {:cont, acc}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_question(_name, %Noul{}), do: :ok
  defp validate_question(_name, %Choice{}), do: :ok

  defp validate_question(name, %Score{criteria: criteria}) do
    validate_score_criteria(name, criteria)
  end

  defp validate_question(name, %{} = raw) do
    type = raw["type"] || raw[:type]

    cond do
      not (is_binary(type) and type != "") ->
        {:error,
         %TypeSafe.ConfigError{
           message:
             ~s(Question "#{name}" must be a question struct or a map with a non-empty string "type".)
         }}

      type in ["choice", "score"] and
          not (Map.has_key?(raw, "criteria") or Map.has_key?(raw, :criteria)) ->
        {:error, %TypeSafe.ConfigError{message: ~s(Question "#{name}" requires "criteria".)}}

      type == "score" ->
        validate_score_criteria(name, raw["criteria"] || raw[:criteria])

      true ->
        :ok
    end
  end

  defp validate_question(name, _other) do
    {:error,
     %TypeSafe.ConfigError{
       message: ~s(Question "#{name}" must be a question struct or a map with a "type".)
     }}
  end

  defp validate_score_criteria(name, criteria) when criteria in [nil, [], %{}] do
    {:error,
     %TypeSafe.ConfigError{
       message: ~s(Score question "#{name}" has no criteria; at least one score is required.)
     }}
  end

  defp validate_score_criteria(_name, _criteria), do: :ok
end

# Encode question structs to their wire form, dropping only the top-level fields left unset (`nil`).
# Nested `nil` values (e.g. an undescribed choice label) are preserved as JSON `null`.
defimpl Jason.Encoder,
  for: [TypeSafe.Question.Noul, TypeSafe.Question.Choice, TypeSafe.Question.Score] do
  def encode(struct, opts) do
    struct
    |> Map.from_struct()
    |> Enum.reject(fn {key, value} -> key != :type and value == nil end)
    |> Map.new()
    |> Jason.Encode.map(opts)
  end
end
