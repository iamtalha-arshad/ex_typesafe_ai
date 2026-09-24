defmodule TypeSafe.RetryTest do
  # Mirrors the behavioral retry cases in tests/test_retry.py, adapted to Req's retry engine.
  use ExUnit.Case, async: true

  alias TypeSafe.Question

  @result %{
    "model" => "jev-latest",
    "usage" => %{"input_tokens" => 1, "output_tokens" => 1},
    "answers" => %{"q" => %{"type" => "noul", "noul" => 0.5}}
  }

  # A client that retries quickly (no real backoff) so tests stay fast.
  defp client(stub, opts \\ []) do
    TypeSafe.new(
      Keyword.merge(
        [api_key: "sk-test", plug: {Req.Test, stub}, max_retries: 2, retry_delay: fn _ -> 0 end],
        opts
      )
    )
  end

  defp call(client), do: TypeSafe.system_one(client, "x", %{"q" => Question.noul()})

  defp counting_stub(stub, fun) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(stub, fn conn ->
      attempt = Agent.get_and_update(counter, &{&1, &1 + 1})
      fun.(conn, attempt)
    end)

    counter
  end

  defp send_json(conn, body, status) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  # test_default_retry_statuses — which statuses are retried by default.
  describe "default retry statuses" do
    retried = [408, 429, 500, 503, 599]
    not_retried = [400, 401, 403, 404, 409, 422]

    for status <- retried do
      @status status
      test "retries #{status} (3 attempts)" do
        stub = Module.concat(__MODULE__, "Retried#{@status}")

        counter =
          counting_stub(stub, fn conn, _ -> send_json(conn, %{"message" => "x"}, @status) end)

        assert {:error, error} = call(client(stub))
        assert error.status == @status
        assert Agent.get(counter, & &1) == 3
      end
    end

    for status <- not_retried do
      @status status
      test "does not retry #{status} (1 attempt)" do
        stub = Module.concat(__MODULE__, "NotRetried#{@status}")

        counter =
          counting_stub(stub, fn conn, _ -> send_json(conn, %{"message" => "x"}, @status) end)

        assert {:error, error} = call(client(stub))
        assert error.status == @status
        assert Agent.get(counter, & &1) == 1
      end
    end
  end

  # test_retry_policy_max_retries — attempt counts scale with :max_retries.
  describe "max_retries" do
    for {max_retries, attempts} <- [{0, 1}, {1, 2}, {4, 5}] do
      @max_retries max_retries
      @attempts attempts
      test "max_retries #{max_retries} yields #{attempts} attempts" do
        stub = Module.concat(__MODULE__, "Max#{@max_retries}")

        counter =
          counting_stub(stub, fn conn, _ -> send_json(conn, %{"message" => "slow"}, 429) end)

        assert {:error, %TypeSafe.RateLimitError{}} =
                 call(client(stub, max_retries: @max_retries))

        assert Agent.get(counter, & &1) == @attempts
      end
    end
  end

  # test_exhausted_retry_preserves_final_http_error — the last response is surfaced.
  test "exhausted retries surface the final HTTP error" do
    statuses = {429, 500, 503}

    counter =
      counting_stub(__MODULE__.Exhausted, fn conn, attempt ->
        status = elem(statuses, attempt)
        send_json(conn, %{"message" => "attempt #{attempt + 1}"}, status)
      end)

    assert {:error, %TypeSafe.InternalServerError{} = error} = call(client(__MODULE__.Exhausted))
    assert error.status == 503
    assert error.body == %{"message" => "attempt 3"}
    assert Agent.get(counter, & &1) == 3
  end

  # test_zero_backoff_retries (recover branch) — a retry can recover to success.
  test "recovers to success after a transient failure" do
    counter =
      counting_stub(__MODULE__.Recover, fn conn, attempt ->
        if attempt == 0,
          do: send_json(conn, %{"message" => "unavailable"}, 503),
          else: send_json(conn, @result, 200)
      end)

    assert {:ok, response} = call(client(__MODULE__.Recover))
    assert response.model == "jev-latest"
    assert Agent.get(counter, & &1) == 2
  end

  # test_connection_retry_recovers — transport errors are retried and can recover.
  test "retries a transport error and recovers" do
    counter =
      counting_stub(__MODULE__.Transport, fn conn, attempt ->
        if attempt < 2,
          do: Req.Test.transport_error(conn, :econnrefused),
          else: send_json(conn, @result, 200)
      end)

    assert {:ok, %TypeSafe.Response.SystemOne{}} = call(client(__MODULE__.Transport))
    assert Agent.get(counter, & &1) == 3
  end

  # test_exhausted_transport_retry — a persistent transport error surfaces as a connection error.
  test "exhausted transport retries surface a ConnectionError" do
    counting_stub(__MODULE__.TransportFail, fn conn, _ ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert {:error, %TypeSafe.ConnectionError{}} = call(client(__MODULE__.TransportFail))
  end
end
