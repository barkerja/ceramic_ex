defmodule Ceramic.SearchResponse do
  @moduledoc "Response from `Ceramic.search/3`."

  defmodule Item do
    @moduledoc "One web page in the results."
    defstruct [:description, :title, :url]
    @type t :: %__MODULE__{description: String.t(), title: String.t(), url: String.t()}
  end

  defmodule SearchMetadata do
    @moduledoc "Timing for the search."
    defstruct [:execution_time]
    @type t :: %__MODULE__{execution_time: float()}
  end

  defmodule Result do
    @moduledoc "Results plus counts and metadata."
    defstruct results: [], search_metadata: nil, total_results: 0

    @type t :: %__MODULE__{
            results: [Ceramic.SearchResponse.Item.t()],
            search_metadata: Ceramic.SearchResponse.SearchMetadata.t(),
            total_results: non_neg_integer()
          }
  end

  defstruct [:request_id, :result]
  @type t :: %__MODULE__{request_id: String.t(), result: Result.t()}

  @spec from_map(map()) :: t()
  def from_map(map) do
    result = map["result"] || %{}

    %__MODULE__{
      request_id: map["requestId"],
      result: %Result{
        results: Enum.map(result["results"] || [], &item/1),
        search_metadata: %SearchMetadata{
          execution_time: get_in(result, ["searchMetadata", "executionTime"])
        },
        total_results: result["totalResults"]
      }
    }
  end

  defp item(map),
    do: %Item{description: map["description"], title: map["title"], url: map["url"]}
end
