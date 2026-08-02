defmodule Canaryd.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    argv = :init.get_plain_arguments() |> Enum.map(&to_string/1)
    Canaryd.CLI.main(argv)
    System.halt(0)
  end
end
