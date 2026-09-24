defmodule TypeSafe.Answer.Noul do
  @moduledoc "A yes/no answer. `:noul` is the probability of \"yes\"/true, from 0 to 1."
  @enforce_keys [:noul]
  defstruct type: "noul", noul: nil

  @type t :: %__MODULE__{type: String.t(), noul: float()}
end

defmodule TypeSafe.Answer.Choice do
  @moduledoc """
  A choice answer.

    * `:choice` — the selected label.
    * `:confidence` — confidence in the selection, from 0 to 1.
    * `:probabilities` — probability of each label, keyed by label name.
  """
  @enforce_keys [:choice, :confidence, :probabilities]
  defstruct type: "choice", choice: nil, confidence: nil, probabilities: %{}

  @type t :: %__MODULE__{
          type: String.t(),
          choice: String.t(),
          confidence: float(),
          probabilities: %{optional(String.t()) => float()}
        }
end

defmodule TypeSafe.Answer.Score do
  @moduledoc """
  A score answer.

    * `:score` — the probability-weighted expected score; may fall between integer levels.
    * `:confidence` — confidence in the score, from 0 to 1.
    * `:legend` — rubric descriptions keyed by integer score level.
    * `:probabilities` — probability of each score level, keyed by integer level.
  """
  @enforce_keys [:score, :confidence, :legend, :probabilities]
  defstruct type: "score", score: nil, confidence: nil, legend: %{}, probabilities: %{}

  @type t :: %__MODULE__{
          type: String.t(),
          score: float(),
          confidence: float(),
          legend: %{optional(integer()) => TypeSafe.Question.content()},
          probabilities: %{optional(integer()) => float()}
        }
end

defmodule TypeSafe.Answer do
  @moduledoc """
  Answers returned for the questions in a `TypeSafe.system_one/4` request.

  Each answer is one of `TypeSafe.Answer.Noul`, `TypeSafe.Answer.Choice`, or `TypeSafe.Answer.Score`,
  matching the type of the question that produced it.
  """

  require Logger

  alias TypeSafe.Answer.{Choice, Noul, Score}

  @typedoc "Any answer struct."
  @type t :: Noul.t() | Choice.t() | Score.t()

  @known_types ~w(noul choice score)

  @doc false
  # Parse a single raw answer. Returns:
  #   * `{:ok, struct}` on success,
  #   * `:skip` for a recognized-map-but-unknown `type` (forward compatibility), or
  #   * `{:error, relative_field_path}` when a known type is missing/has an invalid field.
  @spec parse(String.t(), term()) :: {:ok, t()} | :skip | {:error, String.t()}
  def parse(name, raw) when is_map(raw) do
    case Map.get(raw, "type") do
      "noul" -> parse_noul(raw)
      "choice" -> parse_choice(raw)
      "score" -> parse_score(raw)
      type when is_binary(type) and type not in @known_types -> skip(name, type)
      _ -> {:error, "type"}
    end
  end

  def parse(_name, _raw), do: {:error, "type"}

  defp skip(name, type) do
    Logger.warning(
      "TypeSafe: ignoring answer #{inspect(name)} with unrecognized type #{inspect(type)}"
    )

    :skip
  end

  defp parse_noul(raw) do
    with {:ok, noul} <- number(raw, "noul") do
      {:ok, %Noul{noul: noul}}
    end
  end

  defp parse_choice(raw) do
    with {:ok, choice} <- string(raw, "choice"),
         {:ok, confidence} <- number(raw, "confidence"),
         {:ok, probabilities} <- string_keyed_probabilities(raw, "probabilities") do
      {:ok, %Choice{choice: choice, confidence: confidence, probabilities: probabilities}}
    end
  end

  defp parse_score(raw) do
    with {:ok, score} <- number(raw, "score"),
         {:ok, confidence} <- number(raw, "confidence"),
         {:ok, legend} <- int_keyed_map(raw, "legend"),
         {:ok, probabilities} <- int_keyed_numbers(raw, "probabilities") do
      {:ok,
       %Score{score: score, confidence: confidence, legend: legend, probabilities: probabilities}}
    end
  end

  defp number(raw, key) do
    case Map.fetch(raw, key) do
      {:ok, value} when is_number(value) -> {:ok, value * 1.0}
      _ -> {:error, key}
    end
  end

  defp string(raw, key) do
    case Map.fetch(raw, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      _ -> {:error, key}
    end
  end

  defp string_keyed_probabilities(raw, key) do
    case Map.fetch(raw, key) do
      {:ok, value} when is_map(value) ->
        Enum.reduce_while(value, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
          if is_binary(k) and is_number(v) do
            {:cont, {:ok, Map.put(acc, k, v * 1.0)}}
          else
            {:halt, {:error, "#{key}.#{k}"}}
          end
        end)

      _ ->
        {:error, key}
    end
  end

  defp int_keyed_numbers(raw, key) do
    with {:ok, value} <- fetch_map(raw, key) do
      Enum.reduce_while(value, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
        case {to_int_key(k), v} do
          {{:ok, int_key}, v} when is_number(v) -> {:cont, {:ok, Map.put(acc, int_key, v * 1.0)}}
          _ -> {:halt, {:error, "#{key}.#{k}"}}
        end
      end)
    end
  end

  defp int_keyed_map(raw, key) do
    with {:ok, value} <- fetch_map(raw, key) do
      Enum.reduce_while(value, {:ok, %{}}, fn {k, v}, {:ok, acc} ->
        case to_int_key(k) do
          {:ok, int_key} -> {:cont, {:ok, Map.put(acc, int_key, v)}}
          :error -> {:halt, {:error, "#{key}.#{k}"}}
        end
      end)
    end
  end

  defp fetch_map(raw, key) do
    case Map.fetch(raw, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _ -> {:error, key}
    end
  end

  defp to_int_key(key) when is_integer(key), do: {:ok, key}

  defp to_int_key(key) when is_binary(key) do
    case Integer.parse(key) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp to_int_key(_), do: :error
end
