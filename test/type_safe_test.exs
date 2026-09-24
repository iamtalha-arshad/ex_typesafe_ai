defmodule TypeSafeTest do
  use ExUnit.Case, async: true

  alias TypeSafe.Question

  @result %{
    "model" => "jev-latest",
    "usage" => %{"input_tokens" => 12, "output_tokens" => 3},
    "answers" => %{
      "spam" => %{"type" => "noul", "noul" => 0.98},
      "tone" => %{
        "type" => "choice",
        "choice" => "friendly",
        "confidence" => 0.9,
        "probabilities" => %{"friendly" => 0.9, "hostile" => 0.1}
      },
      "quality" => %{
        "type" => "score",
        "score" => 1.7,
        "confidence" => 0.8,
        "legend" => %{"0" => "bad", "1" => "ok", "2" => "great"},
        "probabilities" => %{"0" => 0.1, "1" => 0.1, "2" => 0.8}
      }
    }
  }

  @model_card %{
    "name" => "jev-latest",
    "description" => "Fast model",
    "release_date" => "2026-08-01"
  }

  defp client(stub, opts \\ []) do
    TypeSafe.new(
      Keyword.merge([api_key: "sk-test", plug: {Req.Test, stub}, max_retries: 0], opts)
    )
  end

  defp respond(conn, body, status \\ 200) do
    conn
    |> Plug.Conn.put_resp_header("x-typesafe-request-id", "req-1")
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  describe "system_one/4" do
    test "sends the expected request body and decodes grouped answers" do
      Req.Test.stub(__MODULE__.SystemOne, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/systemone"
        assert ["Bearer sk-test"] = Plug.Conn.get_req_header(conn, "authorization")
        assert ["application/json"] = Plug.Conn.get_req_header(conn, "accept")
        assert [ua] = Plug.Conn.get_req_header(conn, "user-agent")
        assert ua =~ "typesafe-sdk/"

        {:ok, raw, _conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(raw) == %{
                 "state" => %{"document" => "Hello 🌍"},
                 "model" => "jev-latest",
                 "questions" => %{
                   "spam" => %{"type" => "noul", "instructions" => "Is this spam?"},
                   "tone" => %{
                     "type" => "choice",
                     "instructions" => "Tone?",
                     "criteria" => %{"friendly" => nil, "hostile" => nil}
                   }
                 }
               }

        respond(conn, @result)
      end)

      questions = %{
        "spam" => Question.noul(instructions: "Is this spam?"),
        "tone" =>
          Question.choice(instructions: "Tone?", criteria: %{"friendly" => nil, "hostile" => nil})
      }

      assert {:ok, response} =
               TypeSafe.system_one(
                 client(__MODULE__.SystemOne),
                 %{"document" => "Hello 🌍"},
                 questions
               )

      assert response.model == "jev-latest"
      assert response.request_id == "req-1"
      assert response.usage.input_tokens == 12
      assert response.usage.output_tokens == 3

      assert response.nouls["spam"].noul == 0.98
      assert response.choices["tone"].choice == "friendly"
      assert response.choices["tone"].probabilities == %{"friendly" => 0.9, "hostile" => 0.1}

      score = response.scores["quality"]
      assert score.score == 1.7
      # Score legend/probabilities are re-keyed by integer level.
      assert score.legend == %{0 => "bad", 1 => "ok", 2 => "great"}
      assert score.probabilities == %{0 => 0.1, 1 => 0.1, 2 => 0.8}

      assert Map.keys(response.answers) |> Enum.sort() == ["quality", "spam", "tone"]
    end

    test "applies :model override and shallow-merges :extra_body" do
      Req.Test.stub(__MODULE__.Extra, fn conn ->
        {:ok, raw, _conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(raw) == %{
                 "state" => "hi",
                 "model" => "override-model",
                 "questions" => %{"q" => %{"type" => "noul", "instructions" => "?"}},
                 "beam_width" => 4
               }

        respond(conn, @result)
      end)

      assert {:ok, _} =
               TypeSafe.system_one(
                 client(__MODULE__.Extra),
                 "hi",
                 %{"q" => Question.noul(instructions: "?")},
                 model: "call-model",
                 extra_body: %{"model" => "override-model", "beam_width" => 4}
               )
    end

    test "returns a ConfigError without a request when questions is empty" do
      assert {:error, %TypeSafe.ConfigError{message: message}} =
               TypeSafe.system_one(client(__MODULE__.Empty), "x", %{})

      assert message =~ "At least one question"
    end

    test "raises via system_one!/4" do
      Req.Test.stub(__MODULE__.Bang, fn conn -> respond(conn, %{"error" => "nope"}, 401) end)

      assert_raise TypeSafe.AuthenticationError, fn ->
        TypeSafe.system_one!(client(__MODULE__.Bang), "x", %{"q" => Question.noul()})
      end
    end
  end

  describe "list_models/2" do
    test "decodes the available models" do
      Req.Test.stub(__MODULE__.Models, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v1/models"
        respond(conn, %{"models" => [@model_card]})
      end)

      assert {:ok, response} = TypeSafe.list_models(client(__MODULE__.Models))
      assert [model] = response.models
      assert model.name == "jev-latest"
      assert model.description == "Fast model"
      assert model.release_date == "2026-08-01"
    end

    test "reports the field path of a malformed model" do
      Req.Test.stub(__MODULE__.BadModels, fn conn ->
        respond(conn, %{"models" => [@model_card, Map.delete(@model_card, "release_date")]})
      end)

      assert {:error, %TypeSafe.ResponseValidationError{field_path: "models[1].release_date"}} =
               TypeSafe.list_models(client(__MODULE__.BadModels))
    end
  end

  describe "error mapping" do
    for {status, module} <- [
          {400, TypeSafe.BadRequestError},
          {401, TypeSafe.AuthenticationError},
          {403, TypeSafe.PermissionDeniedError},
          {404, TypeSafe.NotFoundError},
          {422, TypeSafe.UnprocessableEntityError},
          {429, TypeSafe.RateLimitError},
          {503, TypeSafe.InternalServerError}
        ] do
      test "maps HTTP #{status} to #{inspect(module)}" do
        stub = Module.concat(__MODULE__, "Status#{unquote(status)}")
        Req.Test.stub(stub, fn conn -> respond(conn, %{"error" => "boom"}, unquote(status)) end)

        assert {:error, error} =
                 TypeSafe.system_one(client(stub), "x", %{"q" => Question.noul()})

        assert error.__struct__ == unquote(module)
        assert error.status == unquote(status)
        assert error.request_id == "req-1"
        assert Exception.message(error) =~ "boom"
      end
    end

    test "surfaces the server message in the exception" do
      Req.Test.stub(__MODULE__.Msg, fn conn ->
        respond(
          conn,
          %{"detail" => [%{"loc" => ["body", "state"], "msg" => "Field required"}]},
          422
        )
      end)

      assert {:error, %TypeSafe.UnprocessableEntityError{} = error} =
               TypeSafe.system_one(client(__MODULE__.Msg), "x", %{"q" => Question.noul()})

      assert Exception.message(error) =~ "state: Field required"
    end

    test "parses retry-after on a 429" do
      Req.Test.stub(__MODULE__.RateLimited, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "2")
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(429, Jason.encode!(%{"error" => "slow down"}))
      end)

      assert {:error, %TypeSafe.RateLimitError{retry_after_ms: 2000.0}} =
               TypeSafe.system_one(client(__MODULE__.RateLimited), "x", %{"q" => Question.noul()})
    end

    test "maps a timeout to TypeSafe.TimeoutError" do
      Req.Test.stub(__MODULE__.Timeout, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:error, %TypeSafe.TimeoutError{}} =
               TypeSafe.system_one(client(__MODULE__.Timeout), "x", %{"q" => Question.noul()})
    end

    test "raises a validation error when a required answer field is missing" do
      Req.Test.stub(__MODULE__.BadAnswer, fn conn ->
        respond(conn, %{
          "model" => "m",
          "usage" => %{},
          "answers" => %{"c" => %{"type" => "choice", "choice" => "a"}}
        })
      end)

      assert {:error, %TypeSafe.ResponseValidationError{field_path: "answers.c.confidence"}} =
               TypeSafe.system_one(client(__MODULE__.BadAnswer), "x", %{"q" => Question.noul()})
    end

    test "ignores answers with an unknown type (forward compatibility)" do
      Req.Test.stub(__MODULE__.Future, fn conn ->
        respond(conn, %{
          "model" => "m",
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1},
          "answers" => %{
            "spam" => %{"type" => "noul", "noul" => 0.9},
            "mystery" => %{"type" => "aurora", "value" => 3}
          }
        })
      end)

      assert {:ok, response} =
               TypeSafe.system_one(client(__MODULE__.Future), "x", %{"q" => Question.noul()})

      assert Map.keys(response.answers) == ["spam"]
    end
  end

  describe "retry" do
    test "retries a 5xx response and then succeeds" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__.Retry, fn conn ->
        attempt = Agent.get_and_update(counter, &{&1, &1 + 1})

        if attempt == 0 do
          Plug.Conn.send_resp(conn, 503, "unavailable")
        else
          respond(conn, @result)
        end
      end)

      client = client(__MODULE__.Retry, max_retries: 2, retry_delay: fn _ -> 0 end)

      assert {:ok, response} = TypeSafe.system_one(client, "x", %{"q" => Question.noul()})
      assert response.model == "jev-latest"
      assert Agent.get(counter, & &1) == 2
    end
  end

  # test_raw_question_passthrough / test_rich_descriptions — raw maps and rich descriptions
  # travel to the wire untouched.
  describe "request body shaping" do
    test "passes raw map questions through untouched" do
      raw = %{
        "type" => "noul",
        "instructions" => "?",
        "beam_width" => 3,
        "criteria" => %{"future" => "kept"}
      }

      Req.Test.stub(__MODULE__.RawQ, fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["questions"]["q"] == raw
        respond(conn, @result)
      end)

      assert {:ok, _} = TypeSafe.system_one(client(__MODULE__.RawQ), "hi", %{"q" => raw})
    end

    test "keeps rich object/array descriptions in criteria and instructions" do
      Req.Test.stub(__MODULE__.Rich, fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)

        assert Jason.decode!(body)["questions"] == %{
                 "tone" => %{
                   "type" => "choice",
                   "instructions" => %{"task" => "classify"},
                   "criteria" => %{"calm" => %{"note" => nil}, "angry" => ["hostile", "rude"]}
                 }
               }

        respond(conn, @result)
      end)

      question =
        Question.choice(
          instructions: %{"task" => "classify"},
          criteria: %{"calm" => %{"note" => nil}, "angry" => ["hostile", "rude"]}
        )

      assert {:ok, _} = TypeSafe.system_one(client(__MODULE__.Rich), "hi", %{"tone" => question})
    end

    test "rejects an empty score question before any request" do
      Req.Test.stub(__MODULE__.NoNet, fn _conn -> raise "should not reach the network" end)

      assert {:error, %TypeSafe.ConfigError{message: message}} =
               TypeSafe.system_one(client(__MODULE__.NoNet), "x", %{
                 "rating" => %{"type" => "score", "criteria" => []}
               })

      assert message =~ "no criteria"
    end
  end

  # test_invalid_models_response
  describe "invalid models response" do
    bad_bodies = [nil, %{}, %{"models" => "bad"}, %{"models" => [%{"name" => "x"}]}]

    for {body, index} <- Enum.with_index(bad_bodies) do
      @bad_body body
      @bad_idx index
      test "case #{index} raises a validation error" do
        stub = Module.concat(__MODULE__, "BadBody#{@bad_idx}")
        Req.Test.stub(stub, fn conn -> respond(conn, @bad_body) end)

        assert {:error, %TypeSafe.ResponseValidationError{}} = TypeSafe.list_models(client(stub))
      end
    end
  end

  # test_transport_errors — a non-timeout transport error maps to ConnectionError.
  test "maps a connection refusal to TypeSafe.ConnectionError" do
    Req.Test.stub(__MODULE__.ConnErr, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert {:error, %TypeSafe.ConnectionError{}} =
             TypeSafe.list_models(client(__MODULE__.ConnErr))
  end
end
