defmodule CeramicTest do
  use ExUnit.Case, async: false

  @env_vars ["CERAMIC_API_KEY", "CERAMIC_BASE_URL"]

  @response %{
    "requestId" => "req_123",
    "result" => %{
      "results" => [%{"title" => "T", "url" => "https://x", "description" => "D"}],
      "searchMetadata" => %{"executionTime" => 0.42},
      "totalResults" => 1
    }
  }

  setup do
    saved = Map.new(@env_vars, &{&1, System.get_env(&1)})
    Enum.each(@env_vars, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  defp client(opts \\ []) do
    Ceramic.new(
      [api_key: "test-key", plug: {Req.Test, __MODULE__}, retry_delay: 0, retry_log_level: false] ++
        opts
    )
  end

  defp client_with_adapter(adapter, option, value) do
    Ceramic.new(api_key: "k", retry_delay: 0, retry_log_level: false)
    |> Req.Request.register_options([option])
    |> Req.merge([{:adapter, adapter}, {option, value}])
  end

  defp prepared_url(client) do
    client |> Req.merge(url: "/search") |> Req.Request.prepare() |> then(&URI.to_string(&1.url))
  end

  defmodule FailingAdapter do
    def run(request) do
      Agent.update(request.options.calls, &(&1 + 1))
      {request, RuntimeError.exception("adapter blew up")}
    end
  end

  defmodule CapturingAdapter do
    def run(request) do
      send(request.options.test_pid, {:request, request})
      body = JSON.encode!(%{"requestId" => "req_123", "result" => %{}})
      {request, Req.Response.new(status: 200, body: body)}
    end
  end

  describe "new/1" do
    test "default base url joins to /search without a double slash" do
      assert prepared_url(Ceramic.new(api_key: "k")) == "https://api.ceramic.ai/search"
    end

    test "reads api key and base url from the environment" do
      System.put_env("CERAMIC_API_KEY", "env-key")
      System.put_env("CERAMIC_BASE_URL", "https://example.test/")

      client = Ceramic.new()

      assert prepared_url(client) == "https://example.test/search"
      assert Req.Request.get_header(client, "authorization") == ["Bearer env-key"]
    end

    test "keeps the authorization header when the caller adds client headers" do
      client = Ceramic.new(api_key: "k", headers: [{"x-client", "1"}])

      assert Req.Request.get_header(client, "authorization") == ["Bearer k"]
      assert Req.Request.get_header(client, "x-client") == ["1"]
    end

    test "raises Ceramic.Error without an api key" do
      assert_raise Ceramic.Error, ~r/CERAMIC_API_KEY/, fn -> Ceramic.new() end
    end
  end

  describe "search/3" do
    test "posts camelCase body with bearer auth and parses the response" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/search"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert JSON.decode!(body) == %{"query" => "rental laws", "maxResults" => 5}
        Req.Test.json(conn, @response)
      end)

      assert {:ok, response} = Ceramic.search(client(), "rental laws", max_results: 5)

      assert %Ceramic.SearchResponse{
               request_id: "req_123",
               result: %Ceramic.SearchResponse.Result{
                 results: [
                   %Ceramic.SearchResponse.Item{title: "T", url: "https://x", description: "D"}
                 ],
                 search_metadata: %Ceramic.SearchResponse.SearchMetadata{execution_time: 0.42},
                 total_results: 1
               }
             } = response
    end

    test "parses a JSON body even when the content type is not JSON" do
      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(200, JSON.encode!(@response))
      end)

      assert {:ok, %Ceramic.SearchResponse{request_id: "req_123"}} =
               Ceramic.search(client(), "plain content type")
    end

    test "4xx returns an api_status error with the decoded body" do
      Req.Test.expect(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"code" => "invalid_api_key"})
      end)

      assert {:error,
              %Ceramic.Error{
                kind: :api_status,
                status: 401,
                body: %{"code" => "invalid_api_key"},
                message: "Error code: 401 - " <> _
              }} = Ceramic.search(client(), "test invalid key")
    end

    test "4xx with a malformed JSON body keeps the status and raw text" do
      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(502, "<html>bad gateway</html>")
      end)

      assert {:error,
              %Ceramic.Error{
                kind: :api_status,
                status: 502,
                body: "<html>bad gateway</html>",
                message: "<html>bad gateway</html>"
              }} = Ceramic.search(client(max_retries: 0), "malformed")
    end

    test "2xx with a non-JSON body returns an invalid_response error" do
      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.send_resp(200, "<html>proxy page</html>")
      end)

      assert {:error, %Ceramic.Error{kind: :invalid_response, status: 200, body: "<html>" <> _}} =
               Ceramic.search(client(), "proxy")
    end

    test "3xx with redirects disabled returns an api_status error" do
      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "/elsewhere")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, %Ceramic.Error{kind: :api_status, status: 302}} =
               Ceramic.search(client(redirect: false), "moved")
    end

    test "extra_headers are sent and win over the client authorization header" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-custom") == ["yes"]
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer other"]
        Req.Test.json(conn, @response)
      end)

      assert {:ok, _} =
               Ceramic.search(client(), "headers",
                 extra_headers: %{"x-custom" => "yes", "authorization" => "Bearer other"}
               )
    end

    test "extra_query is appended to the request URL" do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/search"
        assert URI.decode_query(conn.query_string) == %{"debug" => "1", "region" => "us"}
        Req.Test.json(conn, @response)
      end)

      assert {:ok, _} =
               Ceramic.search(client(), "query params", extra_query: %{debug: 1, region: "us"})
    end

    test "extra_body is merged over the JSON body and wins on conflict" do
      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert JSON.decode!(body) == %{"query" => "body", "maxResults" => 9, "foo" => "bar"}
        Req.Test.json(conn, @response)
      end)

      assert {:ok, _} =
               Ceramic.search(client(), "body",
                 max_results: 5,
                 extra_body: %{"maxResults" => 9, "foo" => "bar"}
               )
    end

    test "timeout overrides the receive timeout for that call only" do
      client = client_with_adapter(CapturingAdapter, :test_pid, self())

      assert {:ok, _} = Ceramic.search(client, "fast", timeout: 1_234)
      assert_receive {:request, %Req.Request{options: %{receive_timeout: 1_234}}}

      assert {:ok, _} = Ceramic.search(client, "default")
      assert_receive {:request, %Req.Request{options: %{receive_timeout: 60_000}}}
    end

    test "validation errors are returned before any request is sent" do
      assert {:error, %Ceramic.Error{kind: :validation, message: msg}} =
               Ceramic.search(client(), String.duplicate("word ", 51))

      assert msg == "Invalid `query`: expected between 1 and 50 words, got 51."

      assert {:error, %Ceramic.Error{kind: :validation}} = Ceramic.search(client(), "   ")

      assert {:error, %Ceramic.Error{kind: :validation, message: msg}} =
               Ceramic.search(client(), "ok", max_results: 0)

      assert msg == "Invalid `max_results`: expected an integer between 1 and 50, got 0."

      assert {:error, %Ceramic.Error{kind: :validation}} =
               Ceramic.search(client(), "ok", max_results: 51)
    end

    test "retries 5xx and returns the eventual success" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      Req.Test.expect(__MODULE__, 2, fn conn ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
          _ -> Req.Test.json(conn, @response)
        end
      end)

      assert {:ok, %Ceramic.SearchResponse{request_id: "req_123"}} =
               Ceramic.search(client(), "retry me")
    end

    test "x-should-retry on a 2xx does not retry" do
      Req.Test.expect(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_resp_header("x-should-retry", "true") |> Req.Test.json(@response)
      end)

      assert {:ok, _} = Ceramic.search(client(), "no retry on success")
    end

    test "does not retry a non-transport exception" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)
      client = client_with_adapter(FailingAdapter, :calls, calls)

      assert {:error, %Ceramic.Error{kind: :connection, message: "Connection error: " <> _}} =
               Ceramic.search(client, "no retry")

      assert Agent.get(calls, & &1) == 1
    end
  end

  describe "search!/3" do
    test "raises Ceramic.Error" do
      assert_raise Ceramic.Error, fn -> Ceramic.search!(client(), "   ") end
    end
  end
end
