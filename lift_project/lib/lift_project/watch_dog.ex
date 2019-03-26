defmodule WatchDog do
  require Logger

  @moduledoc """
  This module is meant to take care of any order not being handled within
  reasonable time, set by the timer length @watchdog_timer.

  A process starts each time an order's watch_node is set up. If the timer
  of a specific order goes out before the order_complete message is received,
  this order is reinjected to the system by the order distribution logic.
  If everything works as expected, the process is killed when the order_complete
  message is received.
  """

  use GenServer
  @name :watch_dog
  @watchdog_timer 30_000
  @backup_file "watchdog_backup.txt"

  @cab_orders [:cab]
  @hall_orders [:hall_up, :hall_down]

  def start_link(_args) do
    GenServer.start_link(__MODULE__, [], name: @name)
  end

  # API-------------------------------------------------------------------------

  @doc """
  Calls that a new order is added and sets the watchdog timer. If order not
  completed within @watchdog_timer, the order is reinjected.
  """
  def new_order(order) do
    GenServer.call(@name, {:new_order, order})
  end

  @doc """
  Casts that an order is completed and kills the watchdog process.
  """
  def order_complete(order) do
    GenServer.cast(@name, {:order_complete, order})
  end

  @doc """
  Gets the current state of the orders. Returns a map of the states and the orders
  affiliated with the given state. Standby is the state of cab calls from
  dead nodes. Active is the state of running nodes.
  """
  def get_state() do
    GenServer.call(@name, :get)
  end

  # Callbacks-------------------------------------------------------------------
  def init([]) do
    :net_kernel.monitor_nodes(true)
    state = read_from_backup(@backup_file)
    {:ok, state}
  end

  def handle_call({:new_order, order}, _from, state) do
    new_state =
      state
      |> add_order(:active, order)
      |> start_timer(order)

    # timer = Process.send_after(self(), {:order_expiered, order.id}, @watchdog_timer)
    FileBackup.write(new_state, @backup_file)
    {:reply, :ok, %{} = new_state}
  end

  def handle_call(:get, _from, state) do
    {:reply, state, state}
  end

  def handle_cast({:order_complete, order}, state) do
    updated_state =
      state
      |> stop_timer(order)
      |> remove_order(:active, order)

    FileBackup.write(updated_state, @backup_file)
    {:noreply, %{} = updated_state}
  end

  def handle_info({:order_expiered, id}, state) do
    case get_in(state, [:active, id]) do
      nil ->
        {:noreply, state}

      order ->
        reinject_order(order)

        new_state =
          state
          |> remove_order(:timers, order)
          |> remove_order(:active, order)

        FileBackup.write(new_state, @backup_file)
        {:noreply, %{} = new_state}
    end
  end

  def handle_info({:nodedown, node_name}, state) do
    IO.puts("NODE DOWN#{node_name}")

    {:ok, dead_node_orders} = fetch_node(state, node_name)
    {:ok, cab_orders} = fetch_order_type(dead_node_orders, :cab)
    {:ok, hall_orders} = fetch_order_type(dead_node_orders, :hall)

    reinject_order(hall_orders)

    updated_state =
      state
      |> stop_timer(cab_orders)
      |> stop_timer(hall_orders)
      |> move_to_standby(cab_orders)
      |> remove_order(:active, hall_orders)

    FileBackup.write(updated_state, @backup_file)
    {:noreply, %{} = updated_state}
  end

  def handle_info({:nodeup, node_name}, state) do
    standby_orders =
      state
      |> Map.get(:standby)
      |> Map.values()
      |> Enum.filter(fn order -> order.node == node_name end)

    reinject_order(standby_orders)
    new_state = remove_order(state, :standby, standby_orders)
    FileBackup.write(new_state, @backup_file)
    {:noreply, %{} = new_state}
  end

  # Helper functions -----------------------------------------------------------

  @doc """
  Adds an order with its affiliated state to the state map.
  """
  def add_order(state, order_state, order) do
    put_in(state, [order_state, order.id], order)
  end

  @doc """
  When remoove is called with an empty list of orders to remoove
  """
  def remove_order(state, _order_state, []) do
    state
  end

  @doc """
  Removes multiple orders from the state map.
  """
  def remove_order(state, order_state, orders) when is_list(orders) do
    Enum.reduce(orders, state, fn order, int_state ->
      remove_order(int_state, order_state, order)
    end)
  end

  @doc """
  Removes a single order from the state map.
  """
  def remove_order(state, order_state, %Order{} = order) do
    {_complete, new_state} = pop_in(state, [order_state, order.id])
    new_state
  end

  @doc """
  Fetches the node affiliated with the node_name's order.
  """
  def fetch_node(state, node_name) do
    node_orders =
      state
      |> Map.get(:active)
      |> Map.values()
      |> Enum.filter(fn order -> order.node == node_name end)

    {:ok, node_orders}
  end

  @doc """
  Fetch all cab orders.
  """
  def fetch_order_type(orders, :cab) do
    {:ok, Enum.filter(orders, fn order -> order.button_type in @cab_orders end)}
  end

  @doc """
  Fetch all hall orders.
  """
  def fetch_order_type(orders, :hall) do
    {:ok, Enum.filter(orders, fn order -> order.button_type in @hall_orders end)}
  end

  @doc """
  Iterates over the orders with reinject_order(%Order{} = order).
  """
  def reinject_order(orders) when is_list(orders) do
    Enum.each(orders, fn order -> reinject_order(order) end)
  end

  @doc """
  Reinjects the provided order into OrderDistribution.
  """
  def reinject_order(%Order{} = order) do
    Logger.debug("Reinjecting #{inspect(order)}")
    OrderDistribution.new_order(order)
  end

  @doc """
  Iterates over the orders with move_to_standby(state, %Order{} = order).
  """
  def move_to_standby(state, orders)
      when is_list(orders) do
    Enum.reduce(orders, state, fn order, int_state ->
      move_to_standby(int_state, order)
    end)
  end

  @doc """
  Moves the given order to standby state in the state map by deleting the order
  in active state and adding it to the standby state. Returns the rebuilt state map.
  """
  def move_to_standby(state, %Order{} = order) do
    new_active =
      state
      |> Map.get(:active)
      |> Map.delete(order.id)

    new_standby =
      state
      |> Map.get(:standby)
      |> Map.put(order.id, order)

    state
    |> Map.put(:active, new_active)
    |> Map.put(:standby, new_standby)
  end

  def read_from_backup(filename) do
    with {:ok, backup_state} <- FileBackup.read(filename),
         {:ok, active} <-
           filter_recent_orders(backup_state, :active, 120),
         {:ok, standby} <- filter_recent_orders(backup_state, :standby, 10 * 60),
         {:ok, timers} <- start_timer(active) do
      state = %{active: active, standby: standby, timers: timers}
      FileBackup.write(state, @backup_file)
      state
    else
      _ ->
        IO.puts("Failed to read from backup")
        %{active: %{}, standby: %{}, timers: %{}}
    end
  end

  def filter_recent_orders(state, order_state, time) do
    new_state =
      state
      |> Map.get(order_state)
      |> Map.values()
      |> Enum.filter(fn order ->
        Time.diff(Time.utc_now(), order.time) < time
      end)
      |> Map.new(fn order -> {order.id, order} end)

    {:ok, new_state}
  end

  def start_timer(orders) when is_map(orders) do
    timers =
      Enum.reduce(orders, %{}, fn {_id, order}, int_timers -> start_timer(order, int_timers) end)

    {:ok, timers}
  end

  def start_timer(%Order{time: order_time} = order, timers) when is_map(timers) do
    time =
      Time.add(order_time, @watchdog_timer, :millisecond)
      |> Time.diff(Time.utc_now(), :millisecond)

    if time >= 0 do
      timer = Process.send_after(self(), {:order_expiered, order.id}, time)
      Map.put(timers, order.id, timer)
    else
      timer = Process.send_after(self(), {:order_expiered, order.id}, 0)
      Map.put(timers, order.id, timer)
    end
  end

  @doc """
  Start a new timer
  """

  def start_timer(%{} = state, %Order{} = order) do
    timer = Process.send_after(self(), {:order_expiered, order.id}, @watchdog_timer)
    put_in(state, [:timers, order.id], timer)
  end

  def stop_timer(state, orders) when is_list(orders) do
    Enum.reduce(orders, state, fn order, int_state -> stop_timer(int_state, order) end)
  end

  def stop_timer(state, %Order{} = order) do
    {timer, new_state} = pop_in(state, [:timers, order.id])

    if timer != nil do
      Process.cancel_timer(timer)
    end

    new_state
  end
end
