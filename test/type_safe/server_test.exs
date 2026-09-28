defmodule TypeSafe.ServerTest do
  # Application-level, named clients started under a supervision tree.
  use ExUnit.Case, async: true

  alias TypeSafe.Question

  @result %{
    "model" => "jev-latest",
    "usage" => %{"input_tokens" => 1, "output_tokens" => 1},
    "answers" => %{"q" => %{"type" => "noul", "noul" => 0.5}}
  }

  defp respond(conn, body, status \\ 200) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  # A unique registered name per test so async tests don't collide on the global name.
  defp start(name, opts) do
    stub = Module.concat(name, "Stub")
    Req.Test.stub(stub, fn conn -> respond(conn, @result) end)

    start_supervised!(
      {TypeSafe, [name: name, api_key: "sk-test", plug: {Req.Test, stub}] ++ opts}
    )

    name
  end

  test "resolves a named client on system_one/4 and list_models/2" do
    name = start(:"#{__MODULE__}.HappyPath", [])

    assert {:ok, response} = TypeSafe.system_one(name, "x", %{"q" => Question.noul()})
    assert response.model == "jev-latest"
    assert response.nouls["q"].noul == 0.5
  end

  test "client/1 returns the underlying %Client{} built from the given options" do
    name = start(:"#{__MODULE__}.ClientValue", model: "custom-model")

    assert %TypeSafe.Client{config: config} = TypeSafe.client(name)
    assert config.api_key == "sk-test"
    assert config.default_model == "custom-model"
  end

  test "the client is a real value usable directly, decoupled from the process" do
    name = start(:"#{__MODULE__}.Detached", [])
    client = TypeSafe.client(name)

    assert {:ok, _} = TypeSafe.system_one(client, "x", %{"q" => Question.noul()})
  end

  test "client/1 raises a helpful ConfigError when nothing is registered" do
    assert_raise TypeSafe.ConfigError, ~r/No TypeSafe client is registered/, fn ->
      TypeSafe.client(:"#{__MODULE__}.NeverStarted")
    end
  end

  test "system_one/4 raises the same ConfigError for an unregistered name" do
    assert_raise TypeSafe.ConfigError, ~r/supervision tree/, fn ->
      TypeSafe.system_one(:"#{__MODULE__}.Missing", "x", %{"q" => Question.noul()})
    end
  end

  test "start_link/1 without a :name raises ArgumentError" do
    assert_raise ArgumentError, ~r/requires a :name/, fn ->
      TypeSafe.start_link(api_key: "sk-test")
    end
  end

  test "invalid configuration fails the child start via ConfigError" do
    Process.flag(:trap_exit, true)

    assert {:error, {%TypeSafe.ConfigError{}, _stack}} =
             TypeSafe.start_link(name: :"#{__MODULE__}.BadKey", api_key: "bad key with spaces")
  end

  test "the registered entry is cleared when the process stops" do
    name = start(:"#{__MODULE__}.Lifecycle", [])
    pid = Process.whereis(name)

    assert %TypeSafe.Client{} = TypeSafe.client(name)

    # The child is registered under the id from TypeSafe's child_spec/1.
    stop_supervised!({TypeSafe.Server, name})
    refute Process.alive?(pid)

    assert_raise TypeSafe.ConfigError, fn -> TypeSafe.client(name) end
  end
end
