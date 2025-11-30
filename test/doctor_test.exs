defmodule Inky.DoctorTest do
  use ExUnit.Case, async: true

  alias Inky.Doctor

  # Mock modules for testing
  defmodule MockGPIO do
    def open(pin, direction) do
      send(self(), {:gpio_open, pin, direction})
      {:ok, {:gpio_ref, pin}}
    end

    def close(_ref), do: :ok
  end

  defmodule MockGPIOFail do
    def open(_pin, _direction) do
      {:error, :export_failed}
    end

    def close(_ref), do: :ok
  end

  defmodule MockSPI do
    def open(device, _opts) do
      send(self(), {:spi_open, device})
      {:ok, {:spi_ref, device}}
    end

    def close(_ref), do: :ok
  end

  defmodule MockSPIFail do
    def open(_device, _opts) do
      {:error, :enoent}
    end

    def close(_ref), do: :ok
  end

  defmodule MockI2C do
    def open(bus) do
      send(self(), {:i2c_open, bus})
      {:ok, {:i2c_ref, bus}}
    end

    def write_read(_ref, _address, _write_data, _read_bytes) do
      # Return valid EEPROM data: width=212, height=104, color=2 (red), pcb=12, display=11
      {:ok,
       <<212, 0, 104, 0, 2, 12, 11, 0, "2021-03-30 08:58:28.9">>}
    end

    def close(_ref), do: :ok
  end

  defmodule MockI2CFail do
    def open(_bus) do
      {:error, :enoent}
    end

    def close(_ref), do: :ok
  end

  describe "check/1" do
    test "returns success when all checks pass" do
      opts = [
        gpio_mod: MockGPIO,
        spi_mod: MockSPI,
        i2c_mod: MockI2C
      ]

      assert {:ok, results} = Doctor.check(opts)

      assert results.gpio == %{
               busy: {:ok, 17},
               dc: {:ok, 22},
               reset: {:ok, 27}
             }

      assert results.spi == %{device: "spidev0.0", status: :ok}
      assert results.eeprom.status == :ok
      assert results.eeprom.width == 212
      assert results.eeprom.height == 104
    end

    test "returns failures when GPIO fails" do
      opts = [
        gpio_mod: MockGPIOFail,
        spi_mod: MockSPI,
        i2c_mod: MockI2C
      ]

      assert {:error, failures} = Doctor.check(opts)

      assert length(failures) == 3

      assert Enum.any?(failures, fn {resource, error, _hint} ->
               resource == :gpio_busy and error == :export_failed
             end)
    end

    test "returns failures when SPI fails" do
      opts = [
        gpio_mod: MockGPIO,
        spi_mod: MockSPIFail,
        i2c_mod: MockI2C
      ]

      assert {:error, failures} = Doctor.check(opts)

      assert Enum.any?(failures, fn {resource, error, _hint} ->
               resource == :spi and error == :enoent
             end)
    end
  end

  describe "check_gpio/1" do
    test "succeeds when all pins are accessible" do
      opts = [gpio_mod: MockGPIO]

      assert {:ok, results} = Doctor.check_gpio(opts)

      assert results.busy == {:ok, 17}
      assert results.dc == {:ok, 22}
      assert results.reset == {:ok, 27}

      assert_received {:gpio_open, 17, :input}
      assert_received {:gpio_open, 22, :output}
      assert_received {:gpio_open, 27, :output}
    end

    test "supports custom pin mappings" do
      opts = [
        gpio_mod: MockGPIO,
        pin_mappings: %{busy_pin: 5, dc_pin: 6, reset_pin: 7, cs0_pin: 1}
      ]

      assert {:ok, results} = Doctor.check_gpio(opts)

      assert results.busy == {:ok, 5}
      assert results.dc == {:ok, 6}
      assert results.reset == {:ok, 7}
    end

    test "returns failures with hints when GPIO fails" do
      opts = [gpio_mod: MockGPIOFail]

      assert {:error, failures} = Doctor.check_gpio(opts)

      assert length(failures) == 3

      Enum.each(failures, fn {_resource, error, hint} ->
        assert error == :export_failed
        assert hint =~ "gpio group"
      end)
    end
  end

  describe "check_spi/1" do
    test "succeeds when SPI device is accessible" do
      opts = [spi_mod: MockSPI]

      assert {:ok, result} = Doctor.check_spi(opts)

      assert result.device == "spidev0.0"
      assert result.status == :ok
      assert_received {:spi_open, "spidev0.0"}
    end

    test "supports custom chip select pin" do
      opts = [
        spi_mod: MockSPI,
        pin_mappings: %{cs0_pin: 1}
      ]

      assert {:ok, result} = Doctor.check_spi(opts)

      assert result.device == "spidev0.1"
    end

    test "returns error with hint when SPI device not found" do
      opts = [spi_mod: MockSPIFail]

      assert {:error, :enoent, hint} = Doctor.check_spi(opts)

      assert hint =~ "raspi-config"
    end
  end

  describe "check_eeprom/1" do
    test "succeeds and returns display info" do
      opts = [i2c_mod: MockI2C]

      assert {:ok, result} = Doctor.check_eeprom(opts)

      assert result.status == :ok
      assert result.width == 212
      assert result.height == 104
      assert result.color == :red
    end

    test "returns skipped status when I2C not available" do
      opts = [i2c_mod: MockI2CFail]

      assert {:ok, result} = Doctor.check_eeprom(opts)

      assert result.status == :skipped
      assert result.reason =~ "optional"
    end
  end
end
