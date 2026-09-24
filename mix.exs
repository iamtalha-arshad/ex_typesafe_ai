defmodule TypeSafe.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/iamtalha-arshad/ex_typesafe_ai"

  def project do
    [
      app: :ex_typesafe_ai,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "TypeSafe",
      description: "Unofficial, idiomatic Elixir client for the TypeSafe AI API.",
      source_url: @source_url,
      package: package(),
      docs: docs(),
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  # A library: only pull in :logger, don't start an application/supervisor.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.0", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "TypeSafe AI (upstream API)" => "https://typesafe.ai"
      },
      files: ~w(lib .formatter.exs mix.exs README* LICENSE* CHANGELOG*)
    ]
  end

  defp docs do
    [
      main: "TypeSafe",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        Questions: [
          TypeSafe.Question,
          TypeSafe.Question.Noul,
          TypeSafe.Question.Choice,
          TypeSafe.Question.Score
        ],
        Answers: [
          TypeSafe.Answer,
          TypeSafe.Answer.Noul,
          TypeSafe.Answer.Choice,
          TypeSafe.Answer.Score
        ],
        Responses: [
          TypeSafe.Response,
          TypeSafe.Response.SystemOne,
          TypeSafe.Response.ListModels,
          TypeSafe.Response.ModelMetadata,
          TypeSafe.Response.Usage
        ],
        Errors: [
          TypeSafe.Error,
          TypeSafe.APIError,
          TypeSafe.BadRequestError,
          TypeSafe.AuthenticationError,
          TypeSafe.PermissionDeniedError,
          TypeSafe.NotFoundError,
          TypeSafe.UnprocessableEntityError,
          TypeSafe.RateLimitError,
          TypeSafe.InternalServerError,
          TypeSafe.ConnectionError,
          TypeSafe.TimeoutError,
          TypeSafe.ResponseValidationError,
          TypeSafe.ConfigError
        ]
      ]
    ]
  end
end
