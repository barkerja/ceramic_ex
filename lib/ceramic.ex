defmodule Ceramic do
  @moduledoc """
  Client for the Ceramic REST API (`POST /search`).

      client = Ceramic.new(api_key: System.fetch_env!("CERAMIC_API_KEY"))
      {:ok, %Ceramic.SearchResponse{} = response} = Ceramic.search(client, "California rental laws")

  `new/1` reads `CERAMIC_API_KEY` and `CERAMIC_BASE_URL` when the options are absent.
  """

  alias Ceramic.{Error, SearchResponse}

  @default_base_url "https://api.ceramic.ai/"
  @max_query_words 50
  @max_results_range 1..50

  @type client :: Req.Request.t()

  @doc """
  Builds a client. Extra options are passed to `Req.new/1`, so `:plug`, `:retry_delay`
  and friends can be overridden.

  Options: `:api_key`, `:base_url`, `:timeout` (receive timeout in ms, default 60_000),
  `:max_retries` (default 2).
  """
  @spec new(keyword()) :: client()
  def new(opts \\ []) do
    {api_key, opts} = Keyword.pop(opts, :api_key, System.get_env("CERAMIC_API_KEY"))
    {base_url, opts} = Keyword.pop(opts, :base_url, System.get_env("CERAMIC_BASE_URL"))
    {timeout, opts} = Keyword.pop(opts, :timeout, 60_000)
    {max_retries, opts} = Keyword.pop(opts, :max_retries, 2)

    api_key ||
      raise ArgumentError,
            "The api_key client option must be set either by passing api_key to the client " <>
              "or by setting the CERAMIC_API_KEY environment variable"

    [
      base_url: base_url || @default_base_url,
      auth: {:bearer, api_key},
      receive_timeout: timeout,
      connect_options: [timeout: 5_000],
      max_retries: max_retries,
      retry: &should_retry?/2
    ]
    |> Keyword.merge(opts)
    |> Req.new()
  end

  @doc """
  Searches the web. `query` must contain 1 to 50 whitespace-separated words.

  Options: `:max_results` (1..50), `:max_description_length`.
  """
  @spec search(client(), String.t(), keyword()) ::
          {:ok, SearchResponse.t()} | {:error, Error.t()}
  def search(client, query, opts \\ []) do
    max_results = opts[:max_results]

    with :ok <- validate_query(query),
         :ok <- validate_max_results(max_results),
         {:ok, body} <- post_search(client, query, max_results, opts[:max_description_length]) do
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

  defp post_search(client, query, max_results, max_description_length) do
    body =
      %{
        "query" => query,
        "maxResults" => max_results,
        "maxDescriptionLength" => max_description_length
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    case Req.post(client, url: "/search", json: body) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        {:error, Error.invalid_response(response)}

      {:ok, %Req.Response{} = response} ->
        {:error, Error.from_response(response)}

      {:error, exception} ->
        {:error, Error.from_exception(exception)}
    end
  end

  defp validate_query(query) when is_binary(query) do
    case length(String.split(query)) do
      n when n in 1..@max_query_words ->
        :ok

      n ->
        {:error, Error.validation("Invalid `query`: expected between 1 and 50 words, got #{n}.")}
    end
  end

  defp validate_max_results(nil), do: :ok
  defp validate_max_results(n) when is_integer(n) and n in @max_results_range, do: :ok

  defp validate_max_results(n),
    do:
      {:error,
       Error.validation(
         "Invalid `max_results`: expected an integer between 1 and 50, got #{inspect(n)}."
       )}

  defp should_retry?(_request, %Req.Response{status: status} = response) do
    case Req.Response.get_header(response, "x-should-retry") do
      ["true"] -> true
      ["false"] -> false
      _ -> status in [408, 409, 429] or status >= 500
    end
  end

  defp should_retry?(_request, %Req.TransportError{}), do: true
  defp should_retry?(_request, %{__exception__: true}), do: false
end

defmodule Ceramic.Error do
  @moduledoc """
  Raised or returned for every failure. Match on `kind` and `status`:

      {:error, %Ceramic.Error{kind: :api_status, status: 401, body: %{"code" => code}}}

  `kind` is `:validation` (rejected before sending), `:api_status` (any non-2xx),
  `:invalid_response` (2xx whose body is not a JSON object), `:timeout`, or `:connection`.
  `body` is the decoded JSON error body when the API returned one.
  """

  defexception [:message, :kind, :status, :body]

  @type t :: %__MODULE__{
          message: String.t(),
          kind: :validation | :api_status | :invalid_response | :timeout | :connection,
          status: pos_integer() | nil,
          body: term()
        }

  def validation(message), do: %__MODULE__{kind: :validation, message: message}

  def from_response(%Req.Response{status: status, body: body}) do
    message =
      case body do
        "" -> "Error code: #{status}"
        text when is_binary(text) -> text
        decoded -> "Error code: #{status} - #{inspect(decoded)}"
      end

    %__MODULE__{kind: :api_status, status: status, body: body, message: message}
  end

  def invalid_response(%Req.Response{status: status, body: body}) do
    %__MODULE__{
      kind: :invalid_response,
      status: status,
      body: body,
      message: "Data returned by API invalid for expected schema."
    }
  end

  def from_exception(%Req.TransportError{reason: :timeout}),
    do: %__MODULE__{kind: :timeout, message: "Request timed out."}

  def from_exception(exception),
    do: %__MODULE__{
      kind: :connection,
      message: "Connection error: " <> Exception.message(exception)
    }
end
