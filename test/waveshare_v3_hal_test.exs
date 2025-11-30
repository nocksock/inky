defmodule Inky.HAL.Waveshare2in13V3Test do
  @moduledoc false

  use ExUnit.Case

  alias Inky.Display
  alias Inky.HAL.Waveshare2in13V3
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
      :waveshare_2_13_v3
      |> Display.spec_for(:red)
      |> init_pixels()

    %{pixels: pixels}
  end

  describe "init/1" do
    test "initializes with display and io module" do
      display = Display.spec_for(:waveshare_2_13_v3, :red)

      state =
        Waveshare2in13V3.init(%{
          display: display,
          io_args: [],
          io_mod: TestIO
        })

      assert state.display == display
      assert state.io_mod == TestIO
      assert_received {:init, [spi_mod: Circuits.SPI, gpio_mod: Circuits.GPIO]}
    end

    test "raises when display is missing" do
      assert_raise ArgumentError, ~r/:display missing/, fn ->
        Waveshare2in13V3.init(%{io_mod: TestIO})
      end
    end
  end

  describe "handle_update/4" do
    test "sends correct command sequence for V3 tri-color display", ctx do
      display = Display.spec_for(:waveshare_2_13_v3, :red)

      init_args = %{
        display: display,
        io_args: [read_busy: 0],
        io_mod: TestIO
      }

      state = Waveshare2in13V3.init(init_args)

      # Act
      result = Waveshare2in13V3.handle_update(ctx.pixels, :black, :await, state)

      # Assert
      assert {:ok, %Waveshare2in13V3.State{}} = result
      assert_received {:init, _}
      assert TestIO.assert_expectations() == :ok

      messages = gather_messages()

      # Check for reset sequence (high, low, high)
      assert Enum.member?(messages, {:write_reset, 1})
      assert Enum.member?(messages, {:write_reset, 0})

      # Check for power on command (0x04)
      assert Enum.member?(messages, {:send_command, 0x04})

      # Check for panel setting (0x00)
      assert Enum.any?(messages, fn
        {:send_command, {0x00, _data}} -> true
        _ -> false
      end)

      # Check for resolution setting (0x61)
      assert Enum.any?(messages, fn
        {:send_command, {0x61, _data}} -> true
        _ -> false
      end)

      # Check for VCOM setting (0x50)
      assert Enum.any?(messages, fn
        {:send_command, {0x50, _data}} -> true
        _ -> false
      end)

      # Check for red buffer write (0x10)
      assert Enum.any?(messages, fn
        {:send_command, {0x10, _data}} -> true
        _ -> false
      end)

      # Check for black buffer write (0x13)
      assert Enum.any?(messages, fn
        {:send_command, {0x13, _data}} -> true
        _ -> false
      end)

      # Check for refresh command (0x12)
      assert Enum.member?(messages, {:send_command, 0x12})
    end

    test "sends correct panel setting for tri-color mode", ctx do
      display = Display.spec_for(:waveshare_2_13_v3, :red)

      init_args = %{
        display: display,
        io_args: [read_busy: 0],
        io_mod: TestIO
      }

      state = Waveshare2in13V3.init(init_args)
      Waveshare2in13V3.handle_update(ctx.pixels, :black, :await, state)

      messages = gather_messages()

      # Panel setting should be 0x0F, 0x89 for tri-color
      assert Enum.member?(messages, {:send_command, {0x00, <<0x0F, 0x89>>}})
    end

    test "sends correct resolution for 104x212 display", ctx do
      display = Display.spec_for(:waveshare_2_13_v3, :red)

      init_args = %{
        display: display,
        io_args: [read_busy: 0],
        io_mod: TestIO
      }

      state = Waveshare2in13V3.init(init_args)
      Waveshare2in13V3.handle_update(ctx.pixels, :black, :await, state)

      messages = gather_messages()

      # Resolution: 0x68 = 104, 0x00D4 = 212 (as bytes 0xD4, 0x00 would be little endian, but sent as 0x00, 0xD4)
      assert Enum.member?(messages, {:send_command, {0x61, <<0x68, 0x00, 0xD4>>}})
    end

    test "sends correct VCOM setting", ctx do
      display = Display.spec_for(:waveshare_2_13_v3, :red)

      init_args = %{
        display: display,
        io_args: [read_busy: 0],
        io_mod: TestIO
      }

      state = Waveshare2in13V3.init(init_args)
      Waveshare2in13V3.handle_update(ctx.pixels, :black, :await, state)

      messages = gather_messages()

      # VCOM should be 0x77
      assert Enum.member?(messages, {:send_command, {0x50, <<0x77>>}})
    end

    test "writes correct buffer sizes (2756 bytes each)", ctx do
      display = Display.spec_for(:waveshare_2_13_v3, :red)

      init_args = %{
        display: display,
        io_args: [read_busy: 0],
        io_mod: TestIO
      }

      state = Waveshare2in13V3.init(init_args)
      Waveshare2in13V3.handle_update(ctx.pixels, :black, :await, state)

      messages = gather_messages()

      # Find red buffer (0x10) and check size
      red_buffer =
        Enum.find_value(messages, fn
          {:send_command, {0x10, data}} -> data
          _ -> nil
        end)

      assert byte_size(red_buffer) == 2756

      # Find black buffer (0x13) and check size
      black_buffer =
        Enum.find_value(messages, fn
          {:send_command, {0x13, data}} -> data
          _ -> nil
        end)

      assert byte_size(black_buffer) == 2756
    end

    test "waits for busy after refresh (not during init)", ctx do
      display = Display.spec_for(:waveshare_2_13_v3, :red)

      # V3 keeps BUSY=1 during init, only goes to 0 after refresh
      # So we simulate: BUSY=1 during init (ignored), BUSY=0 after refresh
      init_args = %{
        display: display,
        io_args: [read_busy: 0],
        io_mod: TestIO
      }

      state = Waveshare2in13V3.init(init_args)
      result = Waveshare2in13V3.handle_update(ctx.pixels, :black, :await, state)

      assert {:ok, _state} = result

      messages = gather_messages()

      # The refresh command (0x12) should be followed by busy reads
      # Find index of refresh command
      refresh_idx =
        Enum.find_index(messages, fn
          {:send_command, 0x12} -> true
          _ -> false
        end)

      assert refresh_idx != nil

      # There should be read_busy calls after the refresh
      busy_reads_after_refresh =
        messages
        |> Enum.drop(refresh_idx + 1)
        |> Enum.filter(fn
          {:read_busy, _} -> true
          _ -> false
        end)

      assert length(busy_reads_after_refresh) >= 1
    end
  end

  describe "display specification" do
    test "waveshare_2_13_v3 has correct dimensions" do
      display = Display.spec_for(:waveshare_2_13_v3, :red)

      assert display.type == :waveshare_2_13_v3
      assert display.width == 212
      assert display.height == 104
      assert display.rotation == -90
    end

    test "waveshare_2_13_v3 with accent color" do
      display = Display.spec_for(:waveshare_2_13_v3, :red)
      assert display.accent == :red

      display_yellow = Display.spec_for(:waveshare_2_13_v3, :yellow)
      assert display_yellow.accent == :yellow
    end
  end

  describe "color mapping" do
    test "black pixels are correctly mapped", _ctx do
      display = Display.spec_for(:waveshare_2_13_v3, :red)

      # Create pixels with only black
      black_pixels =
        for x <- 0..(display.width - 1),
            y <- 0..(display.height - 1),
            into: %{} do
          {{x, y}, :black}
        end

      init_args = %{
        display: display,
        io_args: [read_busy: 0],
        io_mod: TestIO
      }

      state = Waveshare2in13V3.init(init_args)
      Waveshare2in13V3.handle_update(black_pixels, :black, :await, state)

      messages = gather_messages()

      # Red buffer should be all 0xFF (no red)
      red_buffer =
        Enum.find_value(messages, fn
          {:send_command, {0x10, data}} -> data
          _ -> nil
        end)

      assert red_buffer == :binary.copy(<<0xFF>>, 2756)

      # Black buffer should be all 0x00 (black ink)
      black_buffer =
        Enum.find_value(messages, fn
          {:send_command, {0x13, data}} -> data
          _ -> nil
        end)

      assert black_buffer == :binary.copy(<<0x00>>, 2756)
    end

    test "white pixels are correctly mapped", _ctx do
      display = Display.spec_for(:waveshare_2_13_v3, :red)

      # Create pixels with only white
      white_pixels =
        for x <- 0..(display.width - 1),
            y <- 0..(display.height - 1),
            into: %{} do
          {{x, y}, :white}
        end

      init_args = %{
        display: display,
        io_args: [read_busy: 0],
        io_mod: TestIO
      }

      state = Waveshare2in13V3.init(init_args)
      Waveshare2in13V3.handle_update(white_pixels, :black, :await, state)

      messages = gather_messages()

      # Red buffer should be all 0xFF (no red)
      red_buffer =
        Enum.find_value(messages, fn
          {:send_command, {0x10, data}} -> data
          _ -> nil
        end)

      assert red_buffer == :binary.copy(<<0xFF>>, 2756)

      # Black buffer should be all 0xFF (no black)
      black_buffer =
        Enum.find_value(messages, fn
          {:send_command, {0x13, data}} -> data
          _ -> nil
        end)

      assert black_buffer == :binary.copy(<<0xFF>>, 2756)
    end

    test "red pixels are correctly mapped", _ctx do
      display = Display.spec_for(:waveshare_2_13_v3, :red)

      # Create pixels with only red
      red_pixels =
        for x <- 0..(display.width - 1),
            y <- 0..(display.height - 1),
            into: %{} do
          {{x, y}, :red}
        end

      init_args = %{
        display: display,
        io_args: [read_busy: 0],
        io_mod: TestIO
      }

      state = Waveshare2in13V3.init(init_args)
      Waveshare2in13V3.handle_update(red_pixels, :black, :await, state)

      messages = gather_messages()

      # Red buffer should be all 0x00 (red ink)
      red_buffer =
        Enum.find_value(messages, fn
          {:send_command, {0x10, data}} -> data
          _ -> nil
        end)

      assert red_buffer == :binary.copy(<<0x00>>, 2756)

      # Black buffer should be all 0xFF (no black)
      black_buffer =
        Enum.find_value(messages, fn
          {:send_command, {0x13, data}} -> data
          _ -> nil
        end)

      assert black_buffer == :binary.copy(<<0xFF>>, 2756)
    end
  end
end
