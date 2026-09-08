defmodule Canaryd.MixProject do
  use Mix.Project

  @story_publish "hyperframes-src/canaryd-core-stories/output/publish"
  @github_video ~r/<!-- canaryd-video:start -->.*?<!-- canaryd-video:end -->/s
  @github_codex_video ~r/<!-- codex-process-video:start -->.*?<!-- codex-process-video:end -->/s
  @hexdocs_video """
  <div style="text-align: center;">
    <video
      controls
      playsinline
      preload="metadata"
      poster="https://cdn.jsdelivr.net/gh/ThaddeusJiang/canaryd@3a0e06a53c898c39d4704be53a58ca3051a502ea/hyperframes-src/canaryd-core-stories/output/publish/poster.png"
      style="width: 100%; max-width: 860px; height: auto;"
    >
      <source
        src="https://cdn.jsdelivr.net/gh/ThaddeusJiang/canaryd@3a0e06a53c898c39d4704be53a58ca3051a502ea/hyperframes-src/canaryd-core-stories/output/publish/canaryd-core-stories.mp4"
        type="video/mp4"
      >
      <a href="https://cdn.jsdelivr.net/gh/ThaddeusJiang/canaryd@3a0e06a53c898c39d4704be53a58ca3051a502ea/hyperframes-src/canaryd-core-stories/output/publish/canaryd-core-stories.mp4">
        Download the Canaryd core story reel
      </a>
    </video>
    <br>
    <small>Canaryd's 20-second core story reel.</small>
  </div>
  """
  @hexdocs_codex_video """
  <div style="text-align: center;">
    <video
      controls
      playsinline
      preload="metadata"
      poster="https://cdn.jsdelivr.net/gh/ThaddeusJiang/canaryd@3a0e06a53c898c39d4704be53a58ca3051a502ea/hyperframes-src/codex-screen-control-cleanup/output/poster.png"
      style="width: 100%; max-width: 860px; height: auto;"
    >
      <source
        src="https://cdn.jsdelivr.net/gh/ThaddeusJiang/canaryd@3a0e06a53c898c39d4704be53a58ca3051a502ea/hyperframes-src/codex-screen-control-cleanup/output/codex-screen-control-cleanup.mp4"
        type="video/mp4"
      >
      <a href="https://cdn.jsdelivr.net/gh/ThaddeusJiang/canaryd@3a0e06a53c898c39d4704be53a58ca3051a502ea/hyperframes-src/codex-screen-control-cleanup/output/codex-screen-control-cleanup.mp4">
        Download the Codex screen-control cleanup demo
      </a>
    </video>
    <br>
    <small>Real Activity Monitor evidence followed by a controlled cleanup demo.</small>
  </div>
  """

  def project do
    [
      app: :canaryd,
      version: "0.4.5",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Canaryd.CLI, name: "canaryd"],
      releases: releases(),
      description: description(),
      package: package(),
      deps: deps(),
      source_url: "https://github.com/ThaddeusJiang/canaryd",
      docs: &docs/0
    ]
  end

  def application do
    [extra_applications: [:logger]] ++ application_module()
  end

  defp deps do
    [
      {:burrito, "1.6.0", only: :prod, runtime: false},
      {:ex_doc, "0.40.3", only: :dev, runtime: false, optional: true}
    ]
  end

  defp releases do
    [
      canaryd: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_arm64: [os: :darwin, cpu: :aarch64],
            macos_x86_64: [os: :darwin, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  defp application_module,
    do: if(Mix.env() == :prod, do: [mod: {Canaryd.Application, []}], else: [])

  defp description do
    """
    Canary in the coal mine for your Mac. Detects overheating and apps that
    are alive but silently dead (process running, function stopped) via
    synthetic probes. Self-heals with quiet restarts; only nags you when blocked.
    """
  end

  defp docs do
    exdoc_readme = generate_exdoc_readme!()
    exdoc_story_assets = generate_exdoc_story_assets!()

    [
      main: "readme",
      extras:
        [{exdoc_readme, filename: "readme", source: "README.md"}, "LICENSE"] ++
          Path.wildcard("docs/specs/*.md"),
      formatters: ["html", "markdown"],
      skip_code_autolink_to: [
        "Canaryd.NotificationHelper",
        "Canaryd.Setup.agent_specs/1"
      ],
      assets: %{
        "docs/assets" => "docs/assets",
        exdoc_story_assets => @story_publish
      }
    ]
  end

  defp generate_exdoc_readme! do
    source = File.read!("README.md")

    unless Regex.match?(@github_video, source) do
      raise "README.md is missing the Canaryd core video markers"
    end

    unless Regex.match?(@github_codex_video, source) do
      raise "README.md is missing the Codex process video markers"
    end

    rendered = Regex.replace(@github_video, source, @hexdocs_video)
    rendered = Regex.replace(@github_codex_video, rendered, @hexdocs_codex_video)

    output = "tmp/exdoc/README.md"
    File.mkdir_p!(Path.dirname(output))
    File.write!(output, rendered)
    output
  end

  defp generate_exdoc_story_assets! do
    output = "tmp/exdoc/story-assets"
    File.rm_rf!(output)

    # HexDocs loads video media from an immutable CDN URL. Copy only the static
    # story frames used elsewhere in the README to stay below the 8 MB limit.
    @story_publish
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.filter(&(Path.dirname(&1) |> Path.basename() == "frames"))
    |> Enum.each(fn source ->
      target = Path.join(output, Path.relative_to(source, @story_publish))
      File.mkdir_p!(Path.dirname(target))
      File.cp!(source, target)
    end)

    output
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/ThaddeusJiang/canaryd"},
      files: ~w(lib priv mix.exs README.md LICENSE)
    ]
  end
end
