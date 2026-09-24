defmodule TypeSafe.ConfigTest do
  # Mirrors tests/test_config.py from the Python SDK, adapted to Elixir semantics.
  # Not async: mutates system environment variables.
  use ExUnit.Case, async: false

  alias TypeSafe.Config

  setup do
    for var <- ["TYPESAFE_API_KEY", "TYPESAFE_BASE_URL", "TYPESAFE_DEFAULT_MODEL"] do
      System.delete_env(var)
    end

    :ok
  end

  # test_resolution — default / env / constructor precedence.
  test "resolves defaults with an explicit key" do
    config = Config.resolve!(api_key: "sk-abc")
    assert config.api_key == "sk-abc"
    assert config.base_url == "https://api.typesafe.ai"
    assert config.default_model == "jev-latest"
    assert config.timeout == 10_000
  end

  test "reads values from the environment when no option is given" do
    System.put_env("TYPESAFE_API_KEY", "env-key")
    System.put_env("TYPESAFE_BASE_URL", "https://env.test")
    System.put_env("TYPESAFE_DEFAULT_MODEL", "env-model")

    config = Config.resolve!([])
    assert config.api_key == "env-key"
    assert config.base_url == "https://env.test"
    assert config.default_model == "env-model"
  end

  test "explicit options win over the environment" do
    System.put_env("TYPESAFE_API_KEY", "env-key")
    System.put_env("TYPESAFE_BASE_URL", "https://env.test")
    System.put_env("TYPESAFE_DEFAULT_MODEL", "env-model")

    config = Config.resolve!(api_key: "opt-key", base_url: "https://opt.test", model: "opt-model")
    assert config.api_key == "opt-key"
    assert config.base_url == "https://opt.test"
    assert config.default_model == "opt-model"
  end

  # test_api_key_whitespace — leading/trailing whitespace is trimmed from env and constructor.
  for {source, padding} <-
        for(s <- [:env, :constructor], p <- ["", "\n", "\r\n", " \t\r\n "], do: {s, p}) do
    @source source
    @padding padding
    test "trims #{inspect(padding)} whitespace around a #{source} key" do
      key = "#{@padding}test-key#{@padding}"

      config =
        case @source do
          :env ->
            System.put_env("TYPESAFE_API_KEY", key)
            Config.resolve!([])

          :constructor ->
            System.put_env("TYPESAFE_API_KEY", "env-key")
            Config.resolve!(api_key: key)
        end

      assert config.api_key == "test-key"
    end
  end

  # test_resolution env values are trimmed; trailing slashes stripped from base_url.
  test "trims env values and strips a trailing slash from base_url" do
    System.put_env("TYPESAFE_API_KEY", "  sk-env  ")
    System.put_env("TYPESAFE_BASE_URL", "  https://env.test/  ")

    config = Config.resolve!([])
    assert config.api_key == "sk-env"
    assert config.base_url == "https://env.test"
  end

  # test_empty_env_unset — whitespace-only env values are ignored and defaults apply.
  test "ignores whitespace-only environment values" do
    System.put_env("TYPESAFE_BASE_URL", " \t ")
    System.put_env("TYPESAFE_DEFAULT_MODEL", " \t ")

    config = Config.resolve!(api_key: "sk-abc")
    assert config.base_url == "https://api.typesafe.ai"
    assert config.default_model == "jev-latest"
  end

  # test_missing_key
  for key <- [nil, "", " \t\n "] do
    @key key
    test "raises a missing-key error for #{inspect(key)}" do
      case @key do
        nil -> :ok
        key -> System.put_env("TYPESAFE_API_KEY", key)
      end

      assert_raise TypeSafe.ConfigError, ~r/TYPESAFE_API_KEY/, fn -> Config.resolve!([]) end
    end
  end

  # test_invalid_explicit_key_does_not_fall_back_to_env
  for key <- ["", " \t\r\n ", "\x00private", "private\x00"] do
    @key key
    test "an invalid explicit key #{inspect(key)} does not fall back to the environment" do
      System.put_env("TYPESAFE_API_KEY", "env-key")

      assert_raise TypeSafe.ConfigError, ~r/API key/, fn -> Config.resolve!(api_key: @key) end
    end
  end

  # test_invalid_api_key — control, DEL, space, and non-ASCII characters are rejected,
  # and the credential never appears in the error message.
  for character <- ["\n", "\r", "\t", "\x1f", "\x7f", " ", "é", "​"] do
    @character character
    test "rejects a key containing #{inspect(character)} without leaking it" do
      credential = "ts_live_private"
      key = "#{credential}#{@character}suffix"

      error =
        assert_raise TypeSafe.ConfigError, ~r/API key/, fn -> Config.resolve!(api_key: key) end

      refute error.message =~ credential
    end
  end

  # test_invalid_timeout — only positive integers are accepted.
  for value <- [0, -1] do
    @value value
    test "rejects a non-positive timeout #{value}" do
      assert_raise TypeSafe.ConfigError, ~r/positive integer/, fn ->
        Config.resolve!(api_key: "sk-abc", timeout: @value)
      end
    end
  end
end
