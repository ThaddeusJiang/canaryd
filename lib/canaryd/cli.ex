defmodule Canaryd.CLI do
  @moduledoc "escript entry: check | status | history [target]"

  alias Canaryd.{Checker, Store, System}
  alias Canaryd.Apps.CleanClip

  def main(["check"]) do
    case Checker.run() do
      {:error, :locked} ->
        IO.puts("another check is running, skipping")

      {:skipped_idle, idle, sys} ->
        IO.puts("idle #{idle}s, probes skipped; system warnings: #{length(sys.warnings)}")

      {:checked, _idle, sys, cc} ->
        IO.puts(
          "cleanclip: #{cc.probe} (#{cc.action}), failures=#{cc.failures}; system warnings: #{inspect(sys.warnings)}"
        )
    end
  end

  def main(["status"]) do
    idle = System.idle_seconds()

    Store.with_tables(fn state, events ->
      for target <- [:cleanclip, :system] do
        s = Store.get_state(state, target)

        IO.puts(
          "#{target}: #{s.status} | last_probe=#{s.last_probe} failures=#{s.consecutive_failures} " <>
            "| last_restart=#{fmt(s.last_restart_at)} | updated=#{fmt(s.updated_at)}"
        )
      end

      recent = Store.list_events(events, nil, 5)
      IO.puts("\nrecent events:")
      Enum.each(recent, &IO.puts("  #{fmt(&1.at)}  #{&1.target}  #{&1.type}"))
    end)

    IO.puts("\ncleanclip process alive: #{CleanClip.process_alive?()}")
    IO.puts("user idle: #{idle}s")
  end

  def main(["history"]), do: main(["history", "cleanclip"])

  def main(["history", target]) do
    target_atom = String.to_atom(target)

    Store.with_tables(fn _state, events ->
      events
      |> Store.list_events(target_atom, 50)
      |> Enum.each(fn e ->
        details = Map.drop(e, [:target, :type, :at])
        IO.puts("#{fmt(e.at)}  #{e.type}#{if map_size(details) > 0, do: "  #{inspect(details)}", else: ""}")
      end)
    end)
  end

  def main(_argv) do
    IO.puts("""
    canaryd - Mac health monitor

    usage:
      canaryd check              run one check round (used by launchd)
      canaryd status             current health snapshot
      canaryd history [target]   event timeline (default: cleanclip)
    """)
  end

  defp fmt(nil), do: "-"
  defp fmt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
end
