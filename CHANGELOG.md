# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-09-24

### Added

- Initial release of `ex_typesafe_ai`, an unofficial Elixir client for the TypeSafe AI API.
- `TypeSafe.new/1` to build an immutable, `Req`-backed client from options or environment variables
  (`TYPESAFE_API_KEY`, `TYPESAFE_BASE_URL`, `TYPESAFE_DEFAULT_MODEL`).
- `TypeSafe.system_one/4` and `TypeSafe.system_one!/4` to answer named questions about text or
  structured state.
- `TypeSafe.list_models/2` and `TypeSafe.list_models!/2` to list the models available to the account.
- Question primitives with constructors and structs: `TypeSafe.Question.noul/1`,
  `TypeSafe.Question.choice/1`, and `TypeSafe.Question.score/1`.
- Answer structs grouped on the response by type: `TypeSafe.Answer.Noul`, `TypeSafe.Answer.Choice`,
  and `TypeSafe.Answer.Score`.
- Response structs: `TypeSafe.Response.SystemOne`, `TypeSafe.Response.ListModels`,
  `TypeSafe.Response.ModelMetadata`, and `TypeSafe.Response.Usage`.
- Exception hierarchy in `TypeSafe.Error`, including per-status structs (`TypeSafe.BadRequestError`,
  `TypeSafe.AuthenticationError`, `TypeSafe.RateLimitError`, `TypeSafe.InternalServerError`, ...),
  plus `TypeSafe.ConnectionError`, `TypeSafe.TimeoutError`, `TypeSafe.ResponseValidationError`, and
  `TypeSafe.ConfigError`.
- Automatic retries with exponential backoff for transient failures (HTTP 408/429/5xx and transport
  errors), honoring the `Retry-After` header.

[Unreleased]: https://github.com/iamtalha-arshad/ex_typesafe_ai/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/iamtalha-arshad/ex_typesafe_ai/releases/tag/v0.1.0
