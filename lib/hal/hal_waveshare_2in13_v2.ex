defmodule Inky.HAL.Waveshare2in13V2 do
  @default_io_mod Inky.RpiIO

  @moduledoc """
  An `Inky.HAL` implementation for the Waveshare 2.13" V2 e-ink display
  with SSD1675A display driver.

  This HAL supports both full and partial refresh modes. Partial refresh
  is faster (~0.3s vs ~2s) but should not be used continuously - a full
  refresh should be performed periodically to prevent ghosting.

  ## Usage

      # Start with full refresh (default)
      Inky.HAL.Waveshare2in13V2.handle_update(pixels, border, :await, state)

      # Start with partial refresh
      Inky.HAL.Waveshare2in13V2.handle_update(pixels, border, :await, state, refresh: :partial)

  ## Display Specifications

  - Resolution: 122 x 250 pixels
  - Driver IC: SSD1675A
  - Colors: Black and White
  - Interface: SPI + GPIO

  It delegates to whatever IO module its user provides at init,
  but defaults to #{inspect(@default_io_mod)}
  """

  @behaviour Inky.HAL

  alias Inky.PixelUtil
  import Bitwise

  @color_map_black %{black: 0, miss: 1}
  @color_map_accent %{red: 1, yellow: 1, accent: 1, miss: 0}

  # Display dimensions
  @cols 128
  @rows 250
  @rotation -90

  # Full update LUT (70 bytes from Waveshare V2 driver)
  @lut_full_update <<
    0x80, 0x60, 0x40, 0x00, 0x00, 0x00, 0x00,
    0x10, 0x60, 0x20, 0x00, 0x00, 0x00, 0x00,
    0x80, 0x60, 0x40, 0x00, 0x00, 0x00, 0x00,
    0x10, 0x60, 0x20, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x03, 0x03, 0x00, 0x00, 0x02,
    0x09, 0x09, 0x00, 0x00, 0x02,
    0x03, 0x03, 0x00, 0x00, 0x02,
    0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00,
    0x15, 0x41, 0xA8, 0x32, 0x30, 0x0A
  >>

  # Partial update LUT (70 bytes) for faster refreshes
  @lut_partial_update <<
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x40, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x0A, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00,
    0x15, 0x41, 0xA8, 0x32, 0x30, 0x0A
  >>

  # SSD1675A Commands
  @cmd_driver_output 0x01
  @cmd_gate_voltage 0x03
  @cmd_source_voltage 0x04
  @cmd_deep_sleep 0x10
  @cmd_data_entry_mode 0x11
  @cmd_soft_reset 0x12
  @cmd_activate_display 0x20
  @cmd_display_update_ctrl 0x22
  @cmd_write_ram 0x24
  @cmd_write_alt_ram 0x26
  @cmd_write_vcom 0x2C
  @cmd_write_lut 0x32
  @cmd_border_waveform 0x3C
  @cmd_set_ram_x_position 0x44
  @cmd_set_ram_y_position 0x45
  @cmd_set_ram_x_address 0x4E
  @cmd_set_ram_y_address 0x4F
  @cmd_analog_block_ctrl 0x74
  @cmd_digital_block_ctrl 0x7E

  defmodule State do
    @moduledoc false

    @enforce_keys [:display, :io_mod, :io_state]
    defstruct display: nil,
              io_mod: nil,
              io_state: nil,
              refresh_mode: :full,
              partial_count: 0

    @type t :: %__MODULE__{}
  end

  #
  # API
  #

  @impl Inky.HAL
  def init(args) do
    display = args[:display] || raise(ArgumentError, message: ":display missing in args")
    io_mod = args[:io_mod] || @default_io_mod

    io_args = args[:io_args] || []
    io_args = if Keyword.has_key?(io_args, :gpio_mod), do: io_args, else: [gpio_mod: Circuits.GPIO] ++ io_args
    io_args = if Keyword.has_key?(io_args, :spi_mod), do: io_args, else: [spi_mod: Circuits.SPI] ++ io_args

    %State{
      display: display,
      io_mod: io_mod,
      io_state: io_mod.init(io_args),
      refresh_mode: :full,
      partial_count: 0
    }
  end

  @impl Inky.HAL
  def handle_update(pixels, border, push_policy, state = %State{}) do
    handle_update(pixels, border, push_policy, state, [])
  end

  @doc """
  Extended update with options.

  ## Options

  - `:refresh` - `:full` (default) or `:partial` for fast refresh
  - `:max_partial` - Maximum partial refreshes before forcing full (default: 10)
  """
  def handle_update(pixels, border, push_policy, state = %State{}, opts) do
    refresh_mode = Keyword.get(opts, :refresh, :full)
    max_partial = Keyword.get(opts, :max_partial, 10)

    # Force full refresh after too many partial refreshes
    {refresh_mode, partial_count} =
      if refresh_mode == :partial and state.partial_count >= max_partial do
        {:full, 0}
      else
        case refresh_mode do
          :partial -> {:partial, state.partial_count + 1}
          :full -> {:full, 0}
        end
      end

    black_bits = PixelUtil.pixels_to_bits(pixels, @rows, @cols, @rotation, @color_map_black)
    accent_bits = PixelUtil.pixels_to_bits(pixels, @rows, @cols, @rotation, @color_map_accent)

    # Hardware reset with SSD1675A timings
    state |> set_reset(1) |> sleep(200)
    state |> set_reset(0) |> sleep(5)
    state |> set_reset(1) |> sleep(200)

    case pre_update(state, push_policy) do
      :cont ->
        do_update(state, border, black_bits, accent_bits, refresh_mode)
        {:ok, %{state | refresh_mode: refresh_mode, partial_count: partial_count}}

      :halt ->
        {:error, :device_busy}
    end
  end

  #
  # procedures
  #

  @spec pre_update(State.t(), :await | :once) :: :cont | :halt
  defp pre_update(state, :await) do
    await_device(state)
    :cont
  end

  defp pre_update(state, :once) do
    case read_busy(state) do
      0 -> :cont
      1 -> :halt
    end
  end

  @spec do_update(State.t(), atom(), binary(), binary(), :full | :partial) :: :ok
  defp do_update(state, border, black_bits, accent_bits, refresh_mode) do
    # Software reset
    state |> write_command(@cmd_soft_reset)
    state |> await_device()

    # Initialize display
    init_display(state, refresh_mode)

    # Set border color
    set_border_color(state, border)

    # Set RAM address counters
    state
    |> write_command(@cmd_set_ram_x_address, [0x00])
    |> write_command(@cmd_set_ram_y_address, [@rows - 1, (@rows - 1) >>> 8])

    # Write image data
    state
    |> write_command(@cmd_write_ram, black_bits)
    |> write_command(@cmd_write_alt_ram, accent_bits)

    # Trigger display update
    update_ctrl_value = if refresh_mode == :partial, do: 0x0C, else: 0xC7

    state
    |> write_command(@cmd_display_update_ctrl, [update_ctrl_value])
    |> write_command(@cmd_activate_display)
    |> await_device()

    :ok
  end

  @spec init_display(State.t(), :full | :partial) :: State.t()
  defp init_display(state, refresh_mode) do
    # Analog block control
    state |> write_command(@cmd_analog_block_ctrl, [0x54])
    # Digital block control
    state |> write_command(@cmd_digital_block_ctrl, [0x3B])

    # Driver output control
    state |> write_command(@cmd_driver_output, [@rows - 1, (@rows - 1) >>> 8, 0x00])

    # Data entry mode: X increment, Y decrement
    state |> write_command(@cmd_data_entry_mode, [0x03])

    # Set RAM X window (0 to cols/8 - 1)
    state |> write_command(@cmd_set_ram_x_position, [0x00, div(@cols, 8) - 1])

    # Set RAM Y window (rows-1 to 0)
    state |> write_command(@cmd_set_ram_y_position, [@rows - 1, (@rows - 1) >>> 8, 0x00, 0x00])

    # Border waveform
    state |> write_command(@cmd_border_waveform, [0x03])

    # VCOM voltage
    state |> write_command(@cmd_write_vcom, [0x55])

    # Gate voltage
    state |> write_command(@cmd_gate_voltage, [0x15])

    # Source voltage
    state |> write_command(@cmd_source_voltage, [0x41, 0xA8, 0x32])

    # Load appropriate LUT
    lut_data = if refresh_mode == :partial, do: @lut_partial_update, else: @lut_full_update
    state |> write_command(@cmd_write_lut, lut_data)

    state |> await_device()

    state
  end

  @spec set_border_color(State.t(), atom()) :: State.t()
  defp set_border_color(state, border) do
    accent = state.display.accent

    cond do
      border == :black ->
        write_command(state, @cmd_border_waveform, [0b00000000])

      border in [:red, :accent] and accent == :red ->
        write_command(state, @cmd_border_waveform, [0b00000110])

      border in [:yellow, :accent] and accent == :yellow ->
        write_command(state, @cmd_border_waveform, [0b00001111])

      border == :white ->
        write_command(state, @cmd_border_waveform, [0b00000001])

      true ->
        # Default to white border for B/W displays without accent
        write_command(state, @cmd_border_waveform, [0b00000001])
    end
  end

  @doc """
  Enter deep sleep mode to save power.

  The display must be re-initialized after waking from deep sleep.
  """
  def deep_sleep(state = %State{}) do
    state |> write_command(@cmd_deep_sleep, [0x03])
    state
  end

  #
  # waiting
  #

  @spec await_device(State.t()) :: State.t()
  defp await_device(state) do
    case read_busy(state) do
      1 -> state |> sleep(10) |> await_device()
      0 -> state
    end
  end

  #
  # pipe-able wrappers
  #

  defp sleep(state, sleep_time) do
    io_call(state, :handle_sleep, [sleep_time])
    state
  end

  defp set_reset(state, value) do
    io_call(state, :handle_reset, [value])
    state
  end

  defp read_busy(state) do
    io_call(state, :handle_read_busy)
  end

  defp write_command(state, command) do
    io_call(state, :handle_command, [command])
    state
  end

  defp write_command(state, command, data) do
    io_call(state, :handle_command, [command, data])
    state
  end

  #
  # Behaviour dispatching
  #

  defp io_call(state, op, args \\ []) do
    apply(state.io_mod, op, [state.io_state | args])
  end
end
