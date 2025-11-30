defmodule Inky.HAL.Waveshare2in13V2Test do
  @moduledoc false

  use ExUnit.Case

  alias Inky.Display
  alias Inky.HAL.Waveshare2in13V2
  alias Inky.TestIO

  import Inky.TestUtil, only: [gather_messages: 0, pos2col: 2]

  defp init_pixels(display) do
    for i <- 0..(display.width - 1),
        j <- 0..(display.height - 1),
        do: {{i, j}, pos2col(i, j)},
        into: %{}
  end

  setup_all do
    pixels =
      :waveshare_2_13_v2
      |> Display.spec_for()
      |> init_pixels()

    %{pixels: pixels}
  end

  describe "init/1" do
    test "initializes with display and io module" do
      display = Display.spec_for(:waveshare_2_13_v2)

      state =
        Waveshare2in13V2.init(%{
          display: display,
          io_args: [],
          io_mod: TestIO
        })

      assert state.display == display
      assert state.io_mod == TestIO
      assert state.refresh_mode == :full
      assert state.partial_count == 0
      assert_received {:init, [spi_mod: Circuits.SPI, gpio_mod: Circuits.GPIO]}
    end

    test "raises when display is missing" do
      assert_raise ArgumentError, ~r/:display missing/, fn ->
        Waveshare2in13V2.init(%{io_mod: TestIO})
      end
    end
  end

  describe "handle_update/4 (full refresh)" do
    test "sends correct initialization sequence when device is not busy", ctx do
      display = Display.spec_for(:waveshare_2_13_v2)

      init_args = %{
        display: display,
        io_args: [read_busy: 0],
        io_mod: TestIO
      }

      state = Waveshare2in13V2.init(init_args)

      # Act
      result = Waveshare2in13V2.handle_update(ctx.pixels, :black, :await, state)

      # Assert
      assert {:ok, %Waveshare2in13V2.State{refresh_mode: :full}} = result
      assert_received {:init, _}
      assert TestIO.assert_expectations() == :ok

      messages = gather_messages()

      # Check for reset sequence (high, low, high)
      assert Enum.member?(messages, {:write_reset, 1})
      assert Enum.member?(messages, {:write_reset, 0})

      # Check for software reset command (0x12)
      assert Enum.member?(messages, {:send_command, 0x12})

      # Check for analog block control (0x74)
      assert Enum.member?(messages, {:send_command, {0x74, [0x54]}})

      # Check for digital block control (0x7E)
      assert Enum.member?(messages, {:send_command, {0x7E, [0x3B]}})

      # Check for driver output (0x01)
      assert Enum.member?(messages, {:send_command, {0x01, [249, 0, 0]}})

      # Check for data entry mode (0x11)
      assert Enum.member?(messages, {:send_command, {0x11, [0x03]}})

      # Check for VCOM voltage (0x2C)
      assert Enum.member?(messages, {:send_command, {0x2C, [0x55]}})

      # Check for gate voltage (0x03)
      assert Enum.member?(messages, {:send_command, {0x03, [0x15]}})

      # Check for source voltage (0x04)
      assert Enum.member?(messages, {:send_command, {0x04, [0x41, 0xA8, 0x32]}})

      # Check for display update control with full refresh value (0xC7)
      assert Enum.member?(messages, {:send_command, {0x22, [0xC7]}})

      # Check for activate display (0x20)
      assert Enum.member?(messages, {:send_command, 0x20})

      # Check for RAM write commands (0x24 and 0x26)
      assert Enum.any?(messages, fn
        {:send_command, {0x24, _data}} -> true
        _ -> false
      end)
    end

    test "returns error when device is busy with :once policy", ctx do
      display = Display.spec_for(:waveshare_2_13_v2)

      init_args = %{
        display: display,
        io_args: [read_busy: 1],
        io_mod: TestIO
      }

      state = Waveshare2in13V2.init(init_args)

      # Act
      result = Waveshare2in13V2.handle_update(ctx.pixels, :black, :once, state)

      # Assert
      assert result == {:error, :device_busy}
    end
  end

  describe "handle_update/5 (partial refresh)" do
    test "uses partial LUT when refresh: :partial option is set", ctx do
      display = Display.spec_for(:waveshare_2_13_v2)

      init_args = %{
        display: display,
        io_args: [read_busy: 0],
        io_mod: TestIO
      }

      state = Waveshare2in13V2.init(init_args)

      # Act
      result = Waveshare2in13V2.handle_update(ctx.pixels, :black, :await, state, refresh: :partial)

      # Assert
      assert {:ok, %Waveshare2in13V2.State{refresh_mode: :partial, partial_count: 1}} = result

      messages = gather_messages()

      # Check for display update control with partial refresh value (0x0C)
      assert Enum.member?(messages, {:send_command, {0x22, [0x0C]}})
    end

    test "increments partial_count on partial refresh", ctx do
      display = Display.spec_for(:waveshare_2_13_v2)

      init_args = %{
        display: display,
        io_args: [read_busy: 0],
        io_mod: TestIO
      }

      state = Waveshare2in13V2.init(init_args)

      # First partial refresh
      {:ok, state1} =
        Waveshare2in13V2.handle_update(ctx.pixels, :black, :await, state, refresh: :partial)

      assert state1.partial_count == 1

      # Second partial refresh
      {:ok, state2} =
        Waveshare2in13V2.handle_update(ctx.pixels, :black, :await, state1, refresh: :partial)

      assert state2.partial_count == 2
    end

    test "forces full refresh after max_partial count", ctx do
      display = Display.spec_for(:waveshare_2_13_v2)

      init_args = %{
        display: display,
        io_args: [read_busy: 0],
        io_mod: TestIO
      }

      state = Waveshare2in13V2.init(init_args)

      # Set partial count just below max (default is 10)
      state = %{state | partial_count: 10}

      # This should force a full refresh
      {:ok, result_state} =
        Waveshare2in13V2.handle_update(ctx.pixels, :black, :await, state, refresh: :partial)

      # Should reset to full and count should be 0
      assert result_state.refresh_mode == :full
      assert result_state.partial_count == 0

      messages = gather_messages()

      # Check for display update control with full refresh value (0xC7), not partial (0x0C)
      assert Enum.member?(messages, {:send_command, {0x22, [0xC7]}})
    end

    test "custom max_partial threshold", ctx do
      display = Display.spec_for(:waveshare_2_13_v2)

      init_args = %{
        display: display,
        io_args: [read_busy: 0],
        io_mod: TestIO
      }

      state = Waveshare2in13V2.init(init_args)

      # Set partial count at custom threshold
      state = %{state | partial_count: 5}

      # This should force a full refresh with max_partial: 5
      {:ok, result_state} =
        Waveshare2in13V2.handle_update(ctx.pixels, :black, :await, state,
          refresh: :partial,
          max_partial: 5
        )

      assert result_state.refresh_mode == :full
      assert result_state.partial_count == 0
    end

    test "resets partial_count on full refresh", ctx do
      display = Display.spec_for(:waveshare_2_13_v2)

      init_args = %{
        display: display,
        io_args: [read_busy: 0],
        io_mod: TestIO
      }

      state = Waveshare2in13V2.init(init_args)
      state = %{state | partial_count: 5}

      # Full refresh should reset count
      {:ok, result_state} =
        Waveshare2in13V2.handle_update(ctx.pixels, :black, :await, state, refresh: :full)

      assert result_state.partial_count == 0
    end
  end

  describe "border colors" do
    defp get_border_command do
      Enum.filter(gather_messages(), fn
        {:send_command, {0x3C, _}} -> true
        _ -> false
      end)
    end

    test "black border", ctx do
      display = Display.spec_for(:waveshare_2_13_v2)

      init_args = %{
        display: display,
        io_args: [read_busy: 0],
        io_mod: TestIO
      }

      state = Waveshare2in13V2.init(init_args)
      Waveshare2in13V2.handle_update(ctx.pixels, :black, :await, state)

      border_commands = get_border_command()
      assert Enum.member?(border_commands, {:send_command, {0x3C, [0b00000000]}})
    end

    test "white border", ctx do
      display = Display.spec_for(:waveshare_2_13_v2)

      init_args = %{
        display: display,
        io_args: [read_busy: 0],
        io_mod: TestIO
      }

      state = Waveshare2in13V2.init(init_args)
      Waveshare2in13V2.handle_update(ctx.pixels, :white, :await, state)

      border_commands = get_border_command()
      assert Enum.member?(border_commands, {:send_command, {0x3C, [0b00000001]}})
    end
  end

  describe "display specification" do
    test "waveshare_2_13_v2 has correct dimensions" do
      display = Display.spec_for(:waveshare_2_13_v2)

      assert display.type == :waveshare_2_13_v2
      assert display.width == 122
      assert display.height == 250
      assert display.rotation == -90
    end

    test "waveshare_2_13_v2 with accent color" do
      display = Display.spec_for(:waveshare_2_13_v2, :black)
      assert display.accent == :black
    end
  end
end
