defmodule Canaryd.MixProject do
  use Mix.Project

  @story_publish "hyperframes-src/canaryd-core-stories/output/publish"
  @video_asset_ref "3a0e06a53c898c39d4704be53a58ca3051a502ea"
  @video_cdn "https://cdn.jsdelivr.net/gh/ThaddeusJiang/canaryd@#{@video_asset_ref}"
  @github_video ~r{
    <!--\ readme-video:start\ -->\s*
    <p\ align="center">\s*
      <a\ href="\./(?<mp4>[^"]+\.mp4)\?raw=1">\s*
        <img\ src="\./(?<gif>[^"]+\.gif)"\ width="860"\ alt="[^"]+">\s*
      </a>\s*
      <br>\s*
      <sub>(?<caption>.*?)</sub>\s*
    </p>\s*
    <!--\ readme-video:end\ -->
  }sx
  @github_mp4 ~r{href="\./[^\"]+\.mp4\?raw=1"}
  @github_gif ~r{<img\ src="\./[^\"]+\.gif"}

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
    video_count = length(Regex.scan(@github_video, source))

    unless video_count > 0 and video_count == count_matches(@github_mp4, source) and
             video_count == count_matches(@github_gif, source) do
      raise "every README video must use the readme-video GIF-to-MP4 block"
    end

    rendered =
      Regex.replace(@github_video, source, fn _block, mp4, _gif, caption ->
        hexdocs_video(mp4, caption)
      end)

    output = "tmp/exdoc/README.md"
    File.mkdir_p!(Path.dirname(output))
    File.write!(output, rendered)
    output
  end

  defp count_matches(regex, source), do: length(Regex.scan(regex, source))

  defp hexdocs_video(mp4, caption) do
    video_url = "#{@video_cdn}/#{mp4}"
    poster_url = "#{@video_cdn}/#{Path.join(Path.dirname(mp4), "poster.png")}"

    """
    <div style="text-align: center;">
      <video
        controls
        playsinline
        preload="metadata"
        poster="#{poster_url}"
        style="width: 100%; max-width: 860px; height: auto;"
      >
        <source src="#{video_url}" type="video/mp4">
        <a href="#{video_url}">Download the MP4 video</a>
      </video>
      <br>
      <small>#{caption}</small>
    </div>
    """
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
