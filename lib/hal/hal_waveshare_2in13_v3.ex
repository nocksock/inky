defmodule Inky.HAL.Waveshare2in13V3 do
  @default_io_mod Inky.RpiIO

  @moduledoc """
  An `Inky.HAL` implementation for the Waveshare 2.13" V3 tri-color e-ink display.

  This is a 104x212 pixel tri-color (black/white/red) display. It uses a different
  command set than the V2/V4 variants which use SSD1675 drivers.

  ## Display Specifications

  - Resolution: 212 x 104 pixels (in landscape orientation)
  - Colors: Black, White, Red (tri-color)
  - Interface: SPI + GPIO
  - BUSY logic: 0 = ready, 1 = busy

  ## GPIO Pin Mappings (Waveshare HAT)

  - BUSY: GPIO24
  - DC: GPIO25
  - RST: GPIO17
  - CS: CE0 (spidev0.0)

  ## Usage

      # In Pinksel.Display or similar:
      @waveshare_pins %{
        busy_pin: 24,
        dc_pin: 25,
        reset_pin: 17,
        cs0_pin: 0
      }

      Inky.start_link(:waveshare_2_13_v3, :red, io_args: [pin_mappings: @waveshare_pins])

  It delegates to whatever IO module its user provides at init,
  but defaults to #{inspect(@default_io_mod)}
  """

  @behaviour Inky.HAL

  alias Inky.PixelUtil

  # Color maps for tri-color display
  # Red buffer (0x10): 0 = red ink, 1 = no red
  # Black buffer (0x13): 0 = black ink, 1 = no black
  @color_map_black %{black: 0, miss: 1}
  @color_map_red %{red: 0, yellow: 0, accent: 0, miss: 1}

  # Display dimensions (physical: 104 tall x 212 wide in landscape)
  @cols 104
  @rows 212
  @rotation -90

  # V3 display commands (different from SSD1675!)
  @cmd_power_on 0x04
  @cmd_panel_setting 0x00
  @cmd_resolution 0x61
  @cmd_vcom 0x50
  @cmd_write_red_ram 0x10
  @cmd_write_black_ram 0x13
  @cmd_refresh 0x12

  defmodule State do
    @moduledoc false

    @enforce_keys [:display, :io_mod, :io_state]
    defstruct display: nil,
              io_mod: nil,
              io_state: nil

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
      io_state: io_mod.init(io_args)
    }
  end

  @impl Inky.HAL
  def handle_update(pixels, border, _push_policy, state = %State{}) do
    # Convert pixel map to bitstrings for each color plane
    black_bits = PixelUtil.pixels_to_bits(pixels, @rows, @cols, @rotation, @color_map_black)
    red_bits = PixelUtil.pixels_to_bits(pixels, @rows, @cols, @rotation, @color_map_red)

    # Hardware reset - requires longer delays for V3 display
    # Note: V3 display keeps BUSY=1 through entire init sequence until refresh completes
    # So we do NOT wait for BUSY after reset - just proceed with fixed delays
    state |> set_reset(1) |> sleep(100)
    state |> set_reset(0) |> sleep(10)
    state |> set_reset(1) |> sleep(100)

    do_update(state, border, black_bits, red_bits)
    {:ok, state}
  end

  #
  # procedures
  #

  @spec do_update(State.t(), atom(), binary(), binary()) :: :ok
  defp do_update(state, _border, black_bits, red_bits) do
    # Power on - don't wait, V3 keeps BUSY=1 until refresh completes
    state |> write_command(@cmd_power_on)

    # Panel setting (tri-color mode)
    # 0x0F = LUT from register, 0x89 = scan settings
    state |> write_command(@cmd_panel_setting, <<0x0F, 0x89>>)

    # Resolution: 104 x 212
    # 0x68 = 104, 0x00D4 = 212 (little endian: 0xD4, 0x00)
    state |> write_command(@cmd_resolution, <<0x68, 0x00, 0xD4>>)

    # VCOM and data interval setting
    state |> write_command(@cmd_vcom, <<0x77>>)

    # Write red data (command 0x10)
    state |> write_command(@cmd_write_red_ram, red_bits)

    # Write black data (command 0x13)
    state |> write_command(@cmd_write_black_ram, black_bits)

    # Refresh display and wait for completion
    # This is the ONLY place where we wait - refresh takes ~15s for tri-color
    state |> write_command(@cmd_refresh)
    state |> await_device()

    :ok
  end

  #
  # waiting
  #

  @spec await_device(State.t()) :: State.t()
  defp await_device(state) do
    # V3 display: BUSY = 1 means busy, BUSY = 0 means ready
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

  defp write_command(state, command, data) when is_binary(data) do
    io_call(state, :handle_command, [command, data])
    state
  end

  defp write_command(state, command, data) when is_list(data) do
    io_call(state, :handle_command, [command, :binary.list_to_bin(data)])
    state
  end

  #
  # Behaviour dispatching
  #

  defp io_call(state, op, args \\ []) do
    apply(state.io_mod, op, [state.io_state | args])
  end
end
