# Changelog

## v0.1.1 (2026-10-11)

- Ship `CHANGELOG.md` in the Hex package and render it in the docs

## v0.1.0 (2026-10-11)

Initial release.

### Client

- Add `Ceramic.new/1`, which builds a Req client with bearer auth, `CERAMIC_API_KEY` and `CERAMIC_BASE_URL` fallbacks, timeouts, and retries
- Add `Ceramic.search/3` and `Ceramic.search!/3`, posting camelCase params to `/search`
- Validate query word count and `max_results` before sending
- Parse responses into `SearchResponse`, `Result`, `Item`, and `SearchMetadata` structs
- Return `Ceramic.Error` with `kind` and `status` for validation, API status, invalid response, timeout, and connection failures
- Retry 408, 409, 429, 5xx, and transport errors, honoring `x-should-retry`

### Per-request overrides

- Accept `:timeout` to override the receive timeout for one call
- Accept `:extra_headers` merged into that request's headers
- Accept `:extra_query` as query params on that request only
- Accept `:extra_body` merged over the JSON body, extra values win

### Packaging

- Publish to Hex with ExDoc documentation and the Apache-2.0 license
