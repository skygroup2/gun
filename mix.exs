defmodule Gun.MixProject do
  use Mix.Project

  def project do
    [
      app: :gun,
      version: "1.3.2",
      elixir: "~> 1.10",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Gun, []},
      extra_applications: [
        :logger,
        :cowlib,
        :idna,
        :certifi,
        :ssl_verify_fun,
#        :observer
      ]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:cowlib, "~> 2.11"},
      {:idna, "~> 6.1"},
      {:certifi, "~> 2.7"},
      {:ssl_verify_fun, "~> 1.1"},
      {:gen_statem2, git: "https://github.com/skygroup2/gen_statem2.git", branch: "master"},
      {:jason, "~> 1.2", only: :test},
    ]
  end
end
