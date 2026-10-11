defmodule Ceramic.Error do
  @moduledoc """
  `Ceramic` raises or returns this struct for every failure. Match on `kind` and `status`:

      {:error, %Ceramic.Error{kind: :api_status, status: 401, body: %{"code" => code}}}

  `kind` is `:validation` (rejected before sending, including a missing API key),
  `:api_status` (any non-2xx), `:invalid_response` (2xx whose body is not a JSON object),
  `:timeout`, or `:connection`. `body` is the decoded JSON body when the API returned
  one, otherwise the raw response text.
  """

  defexception [:message, :kind, :status, :body]

  @type kind :: :validation | :api_status | :invalid_response | :timeout | :connection

  @type t :: %__MODULE__{
          message: String.t(),
          kind: kind(),
          status: pos_integer() | nil,
          body: term()
        }

  @doc "Builds a `:validation` error with the given message."
  @spec validation(String.t()) :: t()
  def validation(message), do: %__MODULE__{kind: :validation, message: message}

  @doc "Builds an `:api_status` error from a non-2xx response whose body is already decoded."
  @spec api_status(pos_integer(), term()) :: t()
  def api_status(status, body) do
    message =
      case body do
        "" -> "Error code: #{status}"
        text when is_binary(text) -> text
        decoded -> "Error code: #{status} - #{inspect(decoded)}"
      end

    %__MODULE__{kind: :api_status, status: status, body: body, message: message}
  end

  @doc "Builds an `:invalid_response` error from a 2xx response whose body is not a JSON object."
  @spec invalid_response(pos_integer(), term()) :: t()
  def invalid_response(status, body) do
    %__MODULE__{
      kind: :invalid_response,
      status: status,
      body: body,
      message: "Data returned by API invalid for expected schema."
    }
  end

  @doc "Builds a `:timeout` or `:connection` error from a transport exception."
  @spec from_exception(Exception.t()) :: t()
  def from_exception(%Req.TransportError{reason: :timeout}),
    do: %__MODULE__{kind: :timeout, message: "Request timed out."}

  def from_exception(exception),
    do: %__MODULE__{
      kind: :connection,
      message: "Connection error: " <> Exception.message(exception)
    }
end
