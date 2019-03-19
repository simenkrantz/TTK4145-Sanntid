defmodule LiftProject.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  @floors 4

  def start(_type, _args) do
    # List all child processes to be supervised
    children = [
      {Driver,[]},
      {Lift,[]},
      #{FloorSensor,[]},
      {OrderDistribution,[]},
      {OrderServer,[@floors]},
      {WatchDog, []},
      {ButtonPoller.Supervisor,[4]},
      {FloorPoller,[:floor]},
      {NetworkHandler,[20_000]}
      # Starts a worker by calling: LiftProject.Worker.start_link(arg)
      # {LiftProject.Worker, arg}
    ]
    Node.set_cookie(:HEI)

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: LiftProject.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
