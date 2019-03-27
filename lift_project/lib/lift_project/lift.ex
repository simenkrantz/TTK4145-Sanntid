defmodule Lift do
  @moduledoc """
  Statemachine for controlling the lift given a lift order.
  Keeps track of one order at a time, and drives to complete that specific order.

  A timer is implemented in order to check if the lift cab reaches two different floor
  sensors within a reasonable amount of time. If not, the direction of the cab is set once
  again and the cab continues to drive in the same direction.
  """
  use GenServer

  @name :Lift_FSM
  @door_timer 2_000
  @mooving_timer 3_000
  @enforce_keys [:state, :order, :floor, :dir, :timer]

  defstruct [:state, :order, :floor, :dir, :timer]

  def start_link(args \\ []) do
    GenServer.start_link(__MODULE__, args, name: @name)
  end

  # API ------------------------------------------------------------------------

  @doc """
  Message the state machine that the lift has reached a floor.
  """
  def at_floor(floor) when is_integer(floor) do
    GenServer.cast(@name, {:at_floor, floor})
  end

  @doc """
  Assign a new order to the lift.
  """
  def new_order(%Order{} = order) do
    GenServer.cast(@name, {:new_order, order})
  end

  @doc """
  Get the possition, ie  next floor and current direction of the lift. returns
  error if the state machine is not initialized

  ## Examples
    iex> %Lift{state: :init, order: nil, floor: 0, dir: :up}
    iex> Lift.get_position()
    {:error, :not_ready}

    iex> %Lift{state: :idle, order: nil, floor: 1, dir: :up}
    iex> Lift.get_position()
    {:ok, 1, :up}
  """
  def get_position() do
    GenServer.call(@name, :get_position)
  end

  # Callbacks ----------------------------------------------------------------------

  def init([]) do
    Driver.set_door_open_light(:off)
    Driver.set_motor_direction(:up)
    # Process.sleep(500)

    data = %Lift{
      state: :init,
      order: nil,
      floor: nil,
      dir: :up,
      timer: make_ref()
    }

    {:ok, data}
  end

  def terminate(_reason, _state) do
    Driver.set_motor_direction(:stop)
  end

  def handle_cast({:at_floor, floor}, %Lift{state: :init} = data) do
    IO.inspect(data, label: "init at floor")
    new_data = complete_init(data, floor)
    {:noreply, %Lift{} = new_data}
  end

  def handle_cast({:at_floor, floor}, %Lift{state: _state} = data) do
    IO.inspect(data, label: "at floor")
    new_data = at_floor_event(data, floor)
    {:noreply, %Lift{} = new_data}
  end

  def handle_cast({:new_order, _order}, %Lift{state: :init} = data) do
    {:reply, {:error, :not_ready}, data}
  end

  def handle_cast({:new_order, order}, data) do
    new_data = new_order_event(data, order)
    {:noreply, %Lift{} = new_data}
  end

  def handle_call(:get_position, _from, %Lift{state: :init} = data) do
    {:reply, {:error, :not_ready}, data}
  end

  def handle_call(:get_position, _from, data) do
    {:reply, {:ok, data.floor, data.dir}, data}
  end

  def handle_info(:close_door, %Lift{state: :door_open} = data) do
    new_data = door_close_event(data)
    {:noreply, %Lift{} = new_data}
  end

  def handle_info(:mooving_timer, %Lift{dir: dir, state: :mooving} = data) do
    Driver.set_motor_direction(dir)
    new_data = start_timer(data)
    IO.puts("Timer ran out")
    pid = Process.whereis(:order_server)
    Process.exit(pid, :kill)
    Process.exit(self, :normal)

    {:noreply, new_data}
  end

  # State transitions -------------------------------------------------------------

  @doc """
  This transition will happen on entry to the :door_open state.
  Stops the motor, turns the door light on for a number of seconds specified by
  @door_timer and then tell 'OrderServer' the order has been handled.

  Returns the data struct, with :state set to :door_open.
  """
  defp door_open_transition(%Lift{} = data) do
    Driver.set_motor_direction(:stop)
    Driver.set_door_open_light(:on)
    Process.send_after(self(), :close_door, @door_timer)
    IO.puts("Door open at floor #{data.floor}")
    Map.put(data, :state, :door_open)
  end

  @doc """
  This transition will happen on entry to the :mooving state.
  Turns off the door light and tells the 'OrderServer' the lift leaves a floor
  and in which direction it leaves.

  Returns the updated data struct, with :state set to :idle.
  """
  defp mooving_transition(%Lift{dir: dir} = data) do
    Driver.set_door_open_light(:off)

    new_data =
      Map.put(data, :state, :mooving)
      |> start_timer

    OrderServer.update_lift_position(data.floor, data.dir)
    IO.puts("Mooving #{dir}")
    Driver.set_motor_direction(dir)
    new_data
  end

  @doc """
  This transition will happen on entry to the :idle state.
  Stops the motor, turns off the door light and returns the updated data struct,
  with :state set to :idle.
  """
  defp idle_transition(%Lift{} = data) do
    Driver.set_motor_direction(:stop)
    Driver.set_door_open_light(:off)
    IO.puts("Ideling at floor #{data.floor}")
    Map.put(data, :state, :idle)
  end

  @doc """
  This function takes care of finalizing the initialization of the lift,
  if the lift cab started out between two floors.
  Stops the motor and tell 'OrderServer' the lift is ready at a floor.

  Returns the updated data Map with with :state set to :idle and :floor set to
  the corresponding floor the lift is idling at.
  """
  defp complete_init(data, floor) do
    Driver.set_motor_direction(:stop)
    OrderServer.lift_ready()
    new_data = Map.put(data, :floor, floor)
    NetworkInitialization.boot_node("n", 10_000)
    idle_transition(new_data)
  end

  # Events ----------------------------------------------------------------------------

  @doc """
  This event triggers the state change from :door_open to :idle.
  Turns off the door light and tell 'OrderServer' the given order is complete.

  The data struct is updated with :order set to nil.
  """
  defp door_close_event(%Lift{order: order, dir: dir} = data) do
    Driver.set_door_open_light(:off)
    OrderServer.order_complete(order)
    data = Map.put(data, :order, nil)
    idle_transition(data)
  end

  @doc """
  This event triggers when the lift is in :idle, and a new order needs to be handled.

  Returns the updated data struct.
  """
  defp new_order_event(%Lift{state: :idle} = data, %Order{} = order) do
    if Order.order_at_floor?(order, data.floor) do
      data
      |> add_order(order)
      |> door_open_transition
    else
      data
      |> add_order(order)
      |> update_direction()
      |> at_floor_event()
    end
  end

  @doc """
  This event triggers if :dir is set to :up, with the current floor of the
  lift being below or at the ordered floor.

  If so, the order is added to the data struct.
  """
  defp new_order_event(
         %Lift{floor: current_floor, dir: :up} = data,
         %Order{floor: target_floor} = order
       )
       when current_floor <= target_floor do
    add_order(data, order)
  end

  @doc """
  This event triggers if :dir is set to :down, with the current floor of the
  lift being above or at the ordered floor.

  If so, the order is added to the data struct.
  """
  defp new_order_event(
         %Lift{floor: current_floor, dir: :down} = data,
         %Order{floor: target_floor} = order
       )
       when current_floor >= target_floor do
    add_order(data, order)
  end

  @doc """
  This event cancel the timer in the data struct, and checks whether the cab
  has reached a floor and can open the door, or continue mooving.
  """
  defp at_floor_event(%Lift{floor: floor, order: order, timer: timer} = data) do
    IO.puts("at floor#{floor}")
    Process.cancel_timer(timer)

    case Order.order_at_floor?(order, floor) do
      true -> door_open_transition(data)
      false -> mooving_transition(data)
    end
  end

  @doc """
  Updates :floor to floor in the data struct, before passing the updated struct
  to 'Lift.at_floor_event/1'.
  """
  defp at_floor_event(data, floor) do
    data
    |> Map.put(:floor, floor)
    |> at_floor_event()
  end

  # Helper functions ------------------------------------------------------------------

  @doc """
  Add an order to the data struct defined in 'Lift'.
  """
  defp add_order(%Lift{} = data, order) do
    Map.put(data, :order, order)
  end

  @doc """
  Updates the direction, given the last passed floor of the lift cab
  and the floor on which the order is.
  """
  defp update_direction(%Lift{order: order, floor: floor} = data) do
    if floor < order.floor do
      Map.put(data, :dir, :up)
    else
      Map.put(data, :dir, :down)
    end
  end

  @doc """
  Starts the timer in the data struct, which checks how long it takes for
  a lift cab to  move between two floor sensors.
  Only one timer per lift cab can run at any given time.
  """
  def start_timer(%Lift{timer: timer} = data) do
    Process.cancel_timer(timer)
    timer = Process.send_after(self(), :mooving_timer, @mooving_timer)
    new_data = Map.put(data, :timer, timer)
  end
end
