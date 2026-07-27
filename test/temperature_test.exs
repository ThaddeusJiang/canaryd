defmodule Canaryd.TemperatureTest do
  use ExUnit.Case, async: true

  alias Canaryd.Temperature

  test "parses CPU and GPU temperatures from macmon JSON" do
    output = """
    {"temp":{"cpu_temp_avg":60.77399444580078,"gpu_temp_avg":62.12364196777344}}
    """

    assert Temperature.parse_sample(output) ==
             {:ok, %{cpu_temperature_c: 60.8, gpu_temperature_c: 62.1}}
  end

  test "rejects output without both temperature values" do
    assert Temperature.parse_sample(~s({"temp":{"cpu_temp_avg":60.0}})) ==
             {:error, :invalid_output}
  end

  test "keeps the highest CPU and GPU values in the sample window" do
    output = """
    {"temp":{"cpu_temp_avg":68.1,"gpu_temp_avg":65.2}}
    {"temp":{"cpu_temp_avg":72.4,"gpu_temp_avg":67.0}}
    {"temp":{"cpu_temp_avg":70.2,"gpu_temp_avg":69.8}}
    """

    assert Temperature.parse_sample(output) ==
             {:ok, %{cpu_temperature_c: 72.4, gpu_temperature_c: 69.8}}
  end

  test "requires the supported macmon version" do
    runner = fn
      _path, ["--version"] -> {:ok, "macmon 0.9.0\n"}
      _path, _args -> flunk("must not sample an unsupported version")
    end

    assert Temperature.sample(runner, "/opt/homebrew/bin/macmon") ==
             {:error, {:unsupported_version, "macmon 0.9.0"}}
  end

  test "returns exact temperatures from the supported macmon version" do
    runner = fn
      _path, ["--version"] ->
        {:ok, "macmon 0.8.0\n"}

      _path, ["pipe", "--samples", "3", "--interval", "250"] ->
        {:ok, ~s({"temp":{"cpu_temp_avg":71.24,"gpu_temp_avg":68.86}})}
    end

    assert Temperature.sample(runner, "/opt/homebrew/bin/macmon") ==
             {:ok, %{cpu_temperature_c: 71.2, gpu_temperature_c: 68.9}}
  end
end
