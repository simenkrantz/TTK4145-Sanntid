defmodule OrderDistribution do
  @moduledoc """
  This module takes care of distributing orders,
  both new orders from I/O and reinjected orders from the watchdog.
  """
  use GenServer

  @name :order_distribution
  @valid_orders [:hall_down, :cab, :hall_up]

  def start_link(_args) do
    GenServer.start_link(__MODULE__, [], name: @name)
  end

  # API ------------------------------------------------------------------------

  @doc """
  Adds new order as result of reinjection of order from WatchDog.
  """
  def new_order(order = %Order{}) do
    GenServer.call(@name, {:new_order, order})
  end

  @doc """
  Adds new order as result of I/O action.
  """
  def new_order(floor, button_type)
      when is_integer(floor) and button_type in @valid_orders do
    order = Order.new(floor, button_type)
    new_order(order)
  end

  # Callbacks ------------------------------------------------------------------

  def init(_args) do
    {:ok, %{}}
  end

  def handle_call({:new_order, order}, _from, state) do
    execute_auction(order)
    {:reply, :ok, state}
  end

  # Helper functions -----------------------------------------------------------

  @doc """
  Assigns itself as its own watchdog for the specified order when no other nodes
  are present in the network.
  """
  def assign_watchdog(order, [] = node_list) do
    Map.put(order, :watch_dog, Node.self())
  end

  @doc """
  Assigns a random node in the network as watchdog for the specified order.
  ## Examples
      iex > order = {2,:hall_up}
      iex > node_list = [Node.self]
      iex > assign_watchdog(order, node_list)
      {{2, :hall_up}, Node.self}
  """
  def assign_watchdog(order, node_list) do
    watch_dog =
      ([Node.self() | node_list] -- [order.node])
      |> Enum.random()

    Map.put(order, :watch_dog, watch_dog)
  end

  @doc """
  Executes an edge case auction for the specified order. As this is a cab order,
  the only allowed winner of the auction is the node that called the order.
  """
  def execute_auction(%{button_type: :cab} = order) do
    IO.puts("Cab auction")
    IO.inspect(order)
    find_lowest_bidder([order.node], order)
  end

  @doc """
  Executes an auction to find the lift among the active nodes with lowest cost
  for the specified order.
  """
  def execute_auction(order) do
    find_lowest_bidder([Node.self() | Node.list()], order)
  end

  @doc """
  Collect bids from the nodes in the auction for the specified order. If the order
  isn't already completed, the order is given to the lowest bidder. In addition,
  post-auction processing is performed.
  """
  def find_lowest_bidder(nodes, order) do
    {bids, _bad_nodes} =
      GenServer.multi_call(nodes, :order_server, {:evaluate_cost, order}, 1_000)

    IO.inspect(bids)

    case check_valid_bids(bids) do
      :already_complete ->
        :ok

      :valid ->
        {winner_node, _min_cost} = filter_lowest_bidder(bids)
        post_process_auction(order, winner_node)
    end
  end

  @doc """
  Checks if none of the specified bids says they have completed the order that
  the bids are for.
  """
  def check_valid_bids(bids) do
    case(Enum.any?(bids, fn {_node, reply} -> {:completed, 0} == reply end)) do
      true -> :already_complete
      false -> :valid
    end
  end

  @doc """
  Extracts the node with lowest cost from a list of bids.
  """
  def filter_lowest_bidder(bids) do
    {winner_node, min_bids} =
      Enum.min_by(bids, fn {node_name, cost} -> cost end, fn -> {Node.self(), 0} end)
  end

  @doc """
  Assigns the order to the winner node, as well as assigning a watchdog to the
  same order. Broadcasts the result of the auction to the other nodes.
  """
  def post_process_auction(order, winner_node) do
    IO.puts("Result")

    order
    |> Map.put(:node, winner_node)
    |> assign_watchdog(Node.list())
    |> IO.inspect()
    |> broadcast_result
  end

  @doc """
  Broadcasts an order to all other nodes in the network as a result of an auction.
  """
  def broadcast_result(order) do
    GenServer.multi_call(:order_server, {:new_order, order})
    Node.spawn_link(order.watch_dog, WatchDog, :new_order, [order])
  end
end
