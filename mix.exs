defmodule Canaryd.MixProject do
  use Mix.Project

  @video_asset_ref "eafed5aa52a82c409a7b220a090e64eb1788c70f"
  @video_cdn "https://cdn.jsdelivr.net/gh/ThaddeusJiang/canaryd@#{@video_asset_ref}"
  @github_video ~r{
    <!--\ readme-video:start\ -->\s*
    <p\ align="center">\s*
      <a\ href="\./(?<mp4>[^"]+\.mp4)\?raw=1"\ data-poster="\./(?<poster>[^"]+\.png)">\s*
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
      assets: %{"docs/assets" => "docs/assets"}
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
      Regex.replace(@github_video, source, fn _block, mp4, poster, _gif, caption ->
        hexdocs_video(mp4, poster, caption)
      end)

    output = "tmp/exdoc/README.md"
    File.mkdir_p!(Path.dirname(output))
    File.write!(output, rendered)
    output
  end

  defp count_matches(regex, source), do: length(Regex.scan(regex, source))

  defp hexdocs_video(mp4, poster, caption) do
    video_url = "#{@video_cdn}/#{mp4}"
    poster_url = "#{@video_cdn}/#{poster}"

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

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/ThaddeusJiang/canaryd"},
      files: ~w(lib priv mix.exs README.md LICENSE)
    ]
  end
end
