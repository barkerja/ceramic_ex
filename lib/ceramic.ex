defmodule Ceramic do
  @moduledoc """
  Client for the Ceramic REST API (`POST /search`).

      client = Ceramic.new(api_key: System.fetch_env!("CERAMIC_API_KEY"))
      {:ok, %Ceramic.SearchResponse{} = response} = Ceramic.search(client, "California rental laws")

  `new/1` reads `CERAMIC_API_KEY` and `CERAMIC_BASE_URL` when the options are absent.
  """

  alias Ceramic.{Error, SearchResponse}

  @default_base_url "https://api.ceramic.ai/"
  @query_words_range 1..50
  @max_results_range 1..50

  @type client :: Req.Request.t()

  @doc """
  Builds a client. `new/1` passes extra options to `Req.new/1`, so you can override
  `:plug`, `:retry_delay`, and any other Req option.

  Options: `:api_key`, `:base_url`, `:timeout` (receive timeout in ms, default 60_000),
  `:max_retries` (default 2).

  Raises `Ceramic.Error` with `kind: :validation` when no API key is given and
  `CERAMIC_API_KEY` is unset.
  """
  @spec new(keyword()) :: client()
  def new(opts \\ []) do
    {api_key, opts} = Keyword.pop(opts, :api_key, System.get_env("CERAMIC_API_KEY"))
    {base_url, opts} = Keyword.pop(opts, :base_url, System.get_env("CERAMIC_BASE_URL"))
    {timeout, opts} = Keyword.pop(opts, :timeout, 60_000)
    {max_retries, opts} = Keyword.pop(opts, :max_retries, 2)

    api_key ||
      raise Error.validation(
              "The api_key client option must be set either by passing api_key to the client " <>
                "or by setting the CERAMIC_API_KEY environment variable"
            )

    [
      base_url: base_url || @default_base_url,
      headers: [authorization: "Bearer " <> api_key],
      receive_timeout: timeout,
      connect_options: [timeout: 5_000],
      max_retries: max_retries,
      retry: &should_retry?/2,
      decode_body: false
    ]
    |> Req.new()
    |> Req.merge(opts)
  end

  @doc """
  Searches the web. `query` must contain 1 to 50 whitespace-separated words.

  Options: `:max_results` (1..50), `:max_description_length`.

  Per-request overrides, applied to this call only: `:timeout` (receive timeout in ms),
  `:extra_headers` (map or keyword list, wins over client headers including
  `authorization`), `:extra_query` (map or keyword list of query params), and
  `:extra_body` (map merged over the JSON body, extra values win).

  For response headers or the raw `Req.Response`, call `Req.post(client, url: "/search",
  json: body)` directly.
  """
  @spec search(client(), String.t(), keyword()) ::
          {:ok, SearchResponse.t()} | {:error, Error.t()}
  def search(client, query, opts \\ []) do
    with :ok <- validate_query(query),
         :ok <- validate_max_results(opts[:max_results]),
         {:ok, body} <- post_search(client, query, opts) do
      {:ok, SearchResponse.from_map(body)}
    end
  end

  @doc "Same as `search/3` but raises `Ceramic.Error`."
  @spec search!(client(), String.t(), keyword()) :: SearchResponse.t()
  def search!(client, query, opts \\ []) do
    case search(client, query, opts) do
      {:ok, response} -> response
      {:error, error} -> raise error
    end
  end

  defp post_search(client, query, opts) do
    body =
      %{
        "query" => query,
        "maxResults" => opts[:max_results],
        "maxDescriptionLength" => opts[:max_description_length]
      }
      |> drop_nils()
      |> Map.new()
      |> Map.merge(Map.new(opts[:extra_body] || %{}))

    request_opts =
      drop_nils(
        url: "/search",
        json: body,
        headers: opts[:extra_headers],
        params: opts[:extra_query],
        receive_timeout: opts[:timeout]
      )

    case Req.post(client, request_opts) do
      {:ok, %Req.Response{status: status, body: raw}} -> handle_response(status, decode(raw))
      {:error, exception} -> {:error, Error.from_exception(exception)}
    end
  end

  defp handle_response(status, body) when status in 200..299 and is_map(body), do: {:ok, body}

  defp handle_response(status, body) when status in 200..299,
    do: {:error, Error.invalid_response(status, body)}

  defp handle_response(status, body), do: {:error, Error.api_status(status, body)}

  defp decode(raw) when is_binary(raw) do
    case JSON.decode(raw) do
      {:ok, decoded} -> decoded
      {:error, _} -> raw
    end
  end

  defp decode(raw), do: raw

  defp drop_nils(enum), do: Enum.reject(enum, fn {_k, v} -> is_nil(v) end)

  defp validate_query(query) when is_binary(query) do
    case length(String.split(query)) do
      n when n in @query_words_range ->
        :ok

      n ->
        {:error,
         Error.validation(
           "Invalid `query`: expected between #{@query_words_range.first} and " <>
             "#{@query_words_range.last} words, got #{n}."
         )}
    end
  end

  defp validate_max_results(nil), do: :ok
  defp validate_max_results(n) when is_integer(n) and n in @max_results_range, do: :ok

  defp validate_max_results(n),
    do:
      {:error,
       Error.validation(
         "Invalid `max_results`: expected an integer between #{@max_results_range.first} " <>
           "and #{@max_results_range.last}, got #{inspect(n)}."
       )}

  defp should_retry?(_request, %Req.Response{status: status}) when status in 200..299, do: false

  defp should_retry?(_request, %Req.Response{status: status} = response) do
    case Req.Response.get_header(response, "x-should-retry") do
      ["true"] -> true
      ["false"] -> false
      _ -> status in [408, 409, 429] or status >= 500
    end
  end

  defp should_retry?(_request, %Req.TransportError{}), do: true

  defp should_retry?(_request, %Req.HTTPError{protocol: :http2, reason: reason})
       when reason in [:unprocessed, :pool_not_available],
       do: true

  defp should_retry?(_request, %{__exception__: true}), do: false
end
