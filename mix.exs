defmodule Ceramic.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :ceramic,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Ceramic",
      description: "Elixir client for the Ceramic web search API, built on Req",
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.7"},
      {:plug, "~> 1.0", only: :test},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"API Reference" => "https://docs.ceramic.ai/api-reference/search"},
      files: ~w(lib mix.exs README.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}",
      groups_for_modules: [
        Responses: [
          Ceramic.SearchResponse,
          Ceramic.SearchResponse.Result,
          Ceramic.SearchResponse.Item,
          Ceramic.SearchResponse.SearchMetadata
        ]
      ]
    ]
  end
end
