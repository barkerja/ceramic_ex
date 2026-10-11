# Ceramic

Elixir client for the [Ceramic](https://docs.ceramic.ai/api-reference/search) search API, built on [Req](https://hex.pm/packages/req).

## Installation

```elixir
def deps do
  [
    {:ceramic, "~> 0.1.0"}
  ]
end
```

## Usage

```elixir
client = Ceramic.new()  # reads CERAMIC_API_KEY (and CERAMIC_BASE_URL if set)

{:ok, response} = Ceramic.search(client, "California rental laws", max_results: 5)
response.request_id
response.result.results  # [%Ceramic.SearchResponse.Item{title: ..., url: ..., description: ...}]
```

`Ceramic.search!/3` raises `Ceramic.Error` instead of returning an error tuple.

Per-request overrides apply to one call and leave the client unchanged:

```elixir
Ceramic.search(client, query,
  timeout: 10_000,
  extra_headers: %{"x-request-source" => "cron"},
  extra_query: %{"debug" => 1},
  extra_body: %{"experimental" => true}
)
```

## Errors

Every failure is a `%Ceramic.Error{}`. Match on `kind` and `status`:

```elixir
case Ceramic.search(client, query) do
  {:ok, response} -> response
  {:error, %Ceramic.Error{kind: :validation}} -> # rejected before sending
  {:error, %Ceramic.Error{kind: :api_status, status: 401, body: body}} -> # body["code"]
  {:error, %Ceramic.Error{kind: :timeout}} -> # retries exhausted
end
```

## Retries and timeouts

Requests retry twice on 408, 409, 429, 5xx, and connection errors, with backoff of 1s, 2s, 4s. A `Retry-After` header sets the delay and an `x-should-retry` header overrides the decision. The receive timeout is 60s and the connect timeout is 5s.

Override per client: `Ceramic.new(max_retries: 0, timeout: 10_000)`. Any other option goes to `Req.new/1`.
