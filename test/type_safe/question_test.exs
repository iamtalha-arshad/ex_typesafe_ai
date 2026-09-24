defmodule TypeSafe.QuestionTest do
  # Mirrors tests/test_questions.py from the Python SDK, adapted to Elixir semantics.
  use ExUnit.Case, async: true

  doctest TypeSafe.Question

  alias TypeSafe.Question

  defp wire(question), do: question |> Jason.encode!() |> Jason.decode!()

  describe "constructors" do
    test "noul/1 defaults instructions and criteria to nil" do
      assert %Question.Noul{type: "noul", instructions: nil, criteria: nil} = Question.noul()
    end

    test "choice/1 requires criteria" do
      assert_raise TypeSafe.ConfigError, ~r/choice question requires :criteria/, fn ->
        Question.choice(instructions: "?")
      end
    end

    test "score/1 rejects empty criteria" do
      assert_raise TypeSafe.ConfigError, ~r/must not be empty/, fn ->
        Question.score(criteria: [])
      end
    end
  end

  # test_direct_encoding_omits_only_default_fields
  describe "JSON encoding omits only unset (nil) top-level fields" do
    cases = [
      {Question.noul(), %{"type" => "noul"}},
      {Question.choice(criteria: %{"a" => nil}),
       %{"type" => "choice", "criteria" => %{"a" => nil}}},
      {Question.score(criteria: ["good"]), %{"type" => "score", "criteria" => ["good"]}},
      # Empty string / empty map are values, not "unset", so they are kept.
      {Question.noul(instructions: "", criteria: %{}),
       %{"type" => "noul", "instructions" => "", "criteria" => %{}}},
      # A nested null (undescribed "true" outcome) is preserved.
      {Question.noul(instructions: [], criteria: %{true: nil}),
       %{"type" => "noul", "instructions" => [], "criteria" => %{"true" => nil}}}
    ]

    for {{question, expected}, index} <- Enum.with_index(cases) do
      @question question
      @expected expected
      test "case #{index}" do
        assert wire(@question) == @expected
      end
    end
  end

  # test_optional_noul_criteria
  describe "optional noul criteria" do
    criteria_cases = [
      {nil, %{"type" => "noul", "instructions" => "Spam?"}},
      {%{}, %{"type" => "noul", "instructions" => "Spam?", "criteria" => %{}}},
      {%{true: "Yes"},
       %{"type" => "noul", "instructions" => "Spam?", "criteria" => %{"true" => "Yes"}}},
      {%{false: "No"},
       %{"type" => "noul", "instructions" => "Spam?", "criteria" => %{"false" => "No"}}},
      {%{true: %{"summary" => "Unsolicited", "examples" => ["Buy now"]}},
       %{
         "type" => "noul",
         "instructions" => "Spam?",
         "criteria" => %{"true" => %{"summary" => "Unsolicited", "examples" => ["Buy now"]}}
       }}
    ]

    for {{criteria, expected}, index} <- Enum.with_index(criteria_cases) do
      @criteria criteria
      @expected expected
      test "criteria case #{index}" do
        question = Question.noul(instructions: "Spam?", criteria: @criteria)
        assert wire(question) == @expected
      end
    end
  end

  # test_normalization_preserves_objects
  test "normalize/1 preserves struct questions unchanged and encodes to the wire form" do
    questions = %{
      "noul" => Question.noul(instructions: "Spam?"),
      "choice" => Question.choice(instructions: "Tone?", criteria: %{"calm" => nil}),
      "score" => Question.score(instructions: "Quality?", criteria: ["bad", "good"])
    }

    assert {:ok, ^questions} = Question.normalize(questions)

    assert questions |> Jason.encode!() |> Jason.decode!() == %{
             "noul" => %{"type" => "noul", "instructions" => "Spam?"},
             "choice" => %{
               "type" => "choice",
               "instructions" => "Tone?",
               "criteria" => %{"calm" => nil}
             },
             "score" => %{
               "type" => "score",
               "instructions" => "Quality?",
               "criteria" => ["bad", "good"]
             }
           }
  end

  # test_normalization_preserves_raw_questions
  test "normalize/1 passes raw map questions through untouched" do
    raw = %{
      "type" => "noul",
      "instructions" => "Spam?",
      "weight" => 3,
      "criteria" => %{"future" => "kept"}
    }

    questions = %{"raw" => raw, "typed" => Question.noul(instructions: "Spam?")}

    assert {:ok, result} = Question.normalize(questions)
    assert result["raw"] == raw

    assert questions |> Jason.encode!() |> Jason.decode!() == %{
             "raw" => raw,
             "typed" => %{"type" => "noul", "instructions" => "Spam?"}
           }
  end

  # test_raw_questions_require_structural_keys
  describe "normalize/1 rejects raw questions without a usable type" do
    invalid_cases = [
      %{},
      %{"instructions" => "Missing type"},
      %{"type" => ""},
      %{"type" => nil},
      %{"type" => 1},
      %{"type" => ["future"]},
      "noul",
      nil
    ]

    for {invalid, index} <- Enum.with_index(invalid_cases) do
      @invalid invalid
      test "invalid case #{index}" do
        assert {:error, %TypeSafe.ConfigError{message: message}} =
                 Question.normalize(%{"invalid" => @invalid})

        assert message =~ ~s("invalid")
      end
    end

    # choice/score raw maps missing criteria are also rejected.
    test "raw choice without criteria" do
      assert {:error, %TypeSafe.ConfigError{message: message}} =
               Question.normalize(%{"invalid" => %{"type" => "choice"}})

      assert message =~ "requires"
    end
  end

  # test_empty_score_criteria_is_rejected (raw + typed)
  describe "empty score criteria is rejected by normalize/1" do
    test "raw score with empty criteria" do
      assert {:error, %TypeSafe.ConfigError{message: message}} =
               Question.normalize(%{"rating" => %{"type" => "score", "criteria" => []}})

      assert message =~ ~s("rating" has no criteria)
    end
  end

  # test_covariant_question_mappings — struct, raw, and mixed maps all normalize.
  test "normalize/1 accepts struct, raw, and mixed question maps" do
    mixed = %{
      "one" => Question.noul(instructions: "Spam?"),
      "two" => %{"type" => "choice", "instructions" => "Tone?", "criteria" => %{"calm" => nil}},
      "three" => Question.score(instructions: "Quality?", criteria: ["good"])
    }

    assert {:ok, ^mixed} = Question.normalize(mixed)
  end
end
