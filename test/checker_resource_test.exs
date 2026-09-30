defmodule Canaryd.CheckerResourceTest do
  use ExUnit.Case, async: false

  alias Canaryd.{Checker, DiskPressureConfig, Store, Duration}

  @t0 ~U[2026-09-23 00:00:00Z]
  @gb 1_024 * 1_024 * 1_024

  setup do
    original_home = System.get_env("HOME")

    home =
      Path.join("/private/tmp", "canaryd-resource-check-#{System.unique_integer([:positive])}")

    System.put_env("HOME", home)

    on_exit(fn ->
      if original_home, do: System.put_env("HOME", original_home), else: System.delete_env("HOME")
      File.rm_rf(home)
    end)

    :ok
  end

  test "runs the guarded cleanup when disk pressure enters the threshold" do
    result =
      Store.with_tables(fn state, events ->
        Checker.check_disk_pressure(
          state,
          events,
          %{disk_usage: %{used_percent: 96, available_bytes: 4 * @gb}},
          cleaner: fn ->
            {:ok, %{removed: [%{kind: :rust}], reclaimed_bytes: @gb, failures: [], skipped: %{}}}
          end,
          notifier: fn _title, _message -> :ok end,
          now: @t0
        )
      end)

    assert result.actions == [:cleaned]
    assert result.pressured

    Store.with_tables(fn _state, events ->
      assert [event] = Store.list_events(events, :storage)
      assert event.type == :pressure_cleanup_completed
      assert event.reclaimed_bytes == @gb
    end)
  end

  test "uses the latest configured storage threshold on each check" do
    usage = %{used_percent: 96, available_bytes: 15 * @gb}
    assert DiskPressureConfig.set("10G") == {:ok, 10 * @gb}

    Store.with_tables(fn state, events ->
      cleaner = fn ->
        send(self(), :cleanup_called)
        {:ok, %{removed: [], reclaimed_bytes: @gb, failures: [], skipped: %{}}}
      end

      first =
        Checker.check_disk_pressure(state, events, %{disk_usage: usage},
          cleaner: cleaner,
          notifier: fn _, _ -> :ok end,
          now: @t0
        )

      refute first.pressured
      assert first.actions == []
      refute_received :cleanup_called

      assert DiskPressureConfig.set("20G") == {:ok, 20 * @gb}

      second =
        Checker.check_disk_pressure(state, events, %{disk_usage: usage},
          cleaner: cleaner,
          notifier: fn _, _ -> :ok end,
          now: Duration.add(@t0, Duration.minutes(5))
        )

      assert second.pressured
      assert second.actions == [:cleaned]
      assert_received :cleanup_called
    end)
  end

  test "emergency cleanup starts below 1 GiB even during normal cooldown" do
    usage = fn mib -> %{used_percent: 99, available_bytes: mib * 1_024 * 1_024} end

    Store.with_tables(fn state, events ->
      normal = fn ->
        {:ok, %{removed: [], reclaimed_bytes: 0, failures: [], skipped: %{}}}
      end

      emergency = fn ->
        send(self(), :emergency_called)
        normal.()
      end

      Checker.check_disk_pressure(state, events, %{disk_usage: usage.(2_000)},
        cleaner: normal,
        emergency_cleaner: emergency,
        notifier: fn _, _ -> :ok end,
        now: @t0
      )

      result =
        Checker.check_disk_pressure(state, events, %{disk_usage: usage.(900)},
          cleaner: normal,
          emergency_cleaner: emergency,
          notifier: fn _, _ -> :ok end,
          now: Duration.add(@t0, Duration.minutes(1))
        )

      assert result.actions == [:cleaned]
      assert_received :emergency_called
    end)
  end

  test "invalid storage threshold stops pressure cleanup" do
    config =
      Path.join([
        System.get_env("HOME"),
        "Library",
        "Application Support",
        "canaryd",
        "storage-threshold"
      ])

    File.mkdir_p!(Path.dirname(config))
    File.write!(config, "invalid")

    Store.with_tables(fn state, events ->
      result =
        Checker.check_disk_pressure(
          state,
          events,
          %{disk_usage: %{used_percent: 99, available_bytes: 1 * @gb}},
          cleaner: fn -> flunk("invalid config must not start cleanup") end,
          now: @t0
        )

      assert result.status == :unavailable
      assert result.actions == []
    end)
  end

  test "alerts on sustained swap growth without terminating a process" do
    app = %{
      id: "com.example.app",
      name: "Example",
      pid: 42,
      rss_mb: 3_000.0,
      cpu_percent: 0.2,
      actionable: false
    }

    usage = fn gb ->
      %{total_bytes: 10 * @gb, used_bytes: gb * @gb, free_bytes: (10 - gb) * @gb}
    end

    Store.with_tables(fn state, events ->
      scanner = fn -> {:ok, [app]} end
      notifier = fn title, message -> send(self(), {:notification, title, message}) end

      Checker.check_memory_processes(state, events,
        scanner: scanner,
        notifier: notifier,
        swap_usage: usage.(3),
        now: @t0
      )

      Checker.check_memory_processes(state, events,
        scanner: scanner,
        notifier: notifier,
        swap_usage: usage.(3),
        now: Duration.add(@t0, Duration.minutes(5))
      )

      result =
        Checker.check_memory_processes(state, events,
          scanner: scanner,
          notifier: notifier,
          swap_usage: usage.(4),
          now: Duration.add(@t0, Duration.minutes(10))
        )

      assert result.swap_monitor.actions == [:alerted]
      assert_receive {:notification, "Mac Health", message}
      assert message =~ "not proof of cause"
    end)
  end

  test "alerts on a detached build process without stopping it" do
    process = %{
      id: {"clang", 42},
      name: "clang",
      pid: 42,
      ppid: 1,
      cpu_percent: 2.0,
      rss_mb: 100.0,
      detached: true
    }

    Store.with_tables(fn state, events ->
      scanner = fn -> {:ok, [process]} end
      notifier = fn title, message -> send(self(), {:notification, title, message}) end

      for minute <- [0, 5, 10] do
        result =
          Checker.check_build_processes(state, events,
            scanner: scanner,
            notifier: notifier,
            now: Duration.add(@t0, Duration.minutes(minute))
          )

        if minute == 10, do: assert(result.actions == [:alerted])
      end

      assert_receive {:notification, "Mac Health", message}
      assert message =~ "Detached clang"
    end)
  end
end
