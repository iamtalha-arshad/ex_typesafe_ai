defmodule TypeSafe.ErrorTest do
  # Mirrors tests/test_errors.py and the error-mapping/message cases in tests/test_clients.py,
  # adapted to Elixir semantics.
  use ExUnit.Case, async: true

  alias TypeSafe.Error

  # test_error_mapping — full status table.
  describe "api_error/4 status mapping" do
    cases = [
      {400, TypeSafe.BadRequestError},
      {401, TypeSafe.AuthenticationError},
      {403, TypeSafe.PermissionDeniedError},
      {404, TypeSafe.NotFoundError},
      {422, TypeSafe.UnprocessableEntityError},
      {429, TypeSafe.RateLimitError},
      {500, TypeSafe.InternalServerError},
      {503, TypeSafe.InternalServerError},
      {408, TypeSafe.APIError},
      {409, TypeSafe.APIError},
      {418, TypeSafe.APIError}
    ]

    for {status, module} <- cases do
      @status status
      @module module
      test "maps #{status} to #{inspect(module)}" do
        body = %{"detail" => %{"message" => "Server explanation"}}
        headers = %{"x-typesafe-request-id" => "req_123", "retry-after-ms" => "125"}
        error = Error.api_error(@status, body, headers, "GET https://api.typesafe.ai/v1/models")

        assert error.__struct__ == @module
        assert error.status == @status
        assert error.body == body
        assert error.request_id == "req_123"

        assert Exception.message(error) ==
                 "GET https://api.typesafe.ai/v1/models: #{@status} Server explanation (request_id=req_123)"

        if match?(%TypeSafe.RateLimitError{}, error) do
          assert error.retry_after_ms == 125.0
        end
      end
    end
  end

  # test_api_error_request_context — endpoint, formatted message, request id.
  test "formats the endpoint, message and request id" do
    error =
      Error.api_error(
        429,
        %{"message" => "Too many requests"},
        %{"x-typesafe-request-id" => "req-context"},
        "POST https://api.example.test/prefix/v1/systemone"
      )

    assert error.endpoint == "POST https://api.example.test/prefix/v1/systemone"

    assert Exception.message(error) ==
             "POST https://api.example.test/prefix/v1/systemone: 429 Too many requests (request_id=req-context)"
  end

  # test_error_messages — message extraction precedence.
  describe "message extraction precedence" do
    cases = [
      {%{"error" => "error", "message" => "message", "detail" => "detail"}, "error"},
      {%{"error" => %{"message" => "nested error"}, "message" => "message"}, "nested error"},
      {%{"message" => "message", "detail" => "detail"}, "message"},
      {%{"detail" => "detail"}, "detail"},
      {%{"detail" => %{"message" => "nested detail"}}, "nested detail"},
      {"plain text", "plain text"}
    ]

    for {{body, message}, index} <- Enum.with_index(cases) do
      @body body
      @message message
      test "case #{index}" do
        error = Error.api_error(400, @body, %{})
        assert Exception.message(error) == "400 #{@message}"
      end
    end

    test "joins FastAPI-style validation detail lists" do
      body = %{
        "detail" => [
          %{"loc" => ["body", "questions", "q", "score", "criteria", 0], "msg" => "Invalid"},
          %{"msg" => "Missing"},
          %{}
        ]
      }

      assert Error.extract_message(body) == "questions.q.score.criteria.0: Invalid; Missing"
    end
  end

  # test_error_body_edge_cases — deterministic bodies (single top-level key or non-map).
  describe "error body edge cases" do
    cases = [
      {nil, "status code (no body)"},
      {[], "[]"},
      {42, "42"},
      {"not JSON", "not JSON"},
      {%{"detail" => [nil, 42, %{"msg" => 4}]}, ~s({"detail":[null,42,{"msg":4}]})}
    ]

    for {{body, message}, index} <- Enum.with_index(cases) do
      @body body
      @message message
      test "case #{index}" do
        assert Exception.message(Error.api_error(400, @body, %{})) == "400 #{@message}"
      end
    end

    test "keeps a long plain-string body in full" do
      body = String.duplicate("x", 201)
      assert Exception.message(Error.api_error(400, body, %{})) == "400 " <> body
    end

    test "truncates a long unstructured JSON body with an ellipsis" do
      body = %{"unknown" => String.duplicate("x", 201)}
      message = Exception.message(Error.api_error(400, body, %{}))
      assert String.starts_with?(message, ~s(400 {"unknown":"))
      assert String.ends_with?(message, "…")
      # "400 " + 200 body chars + ellipsis.
      assert String.length(message) == 4 + 200 + 1
    end
  end

  # test_message_override behavior: a message-less body renders as just the status.
  test "renders a message-less body as just the status" do
    assert Exception.message(Error.api_error(500, nil, %{})) == "500 status code (no body)"
  end

  # test_error_mapping / RateLimitError retry-after parsing.
  describe "retry-after parsing on 429" do
    cases = [
      {%{"retry-after-ms" => "1500"}, 1500.0},
      {%{"retry-after" => "2"}, 2000.0},
      {%{"retry-after-ms" => "0", "retry-after" => "50"}, 0.0},
      {%{}, nil}
    ]

    for {{headers, expected}, index} <- Enum.with_index(cases) do
      @headers headers
      @expected expected
      test "case #{index}" do
        assert %TypeSafe.RateLimitError{retry_after_ms: actual} =
                 Error.api_error(429, nil, @headers)

        assert actual == @expected
      end
    end
  end
end
