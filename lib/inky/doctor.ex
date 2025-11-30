defmodule Inky.Doctor do
  @moduledoc """
  Diagnostic utilities for troubleshooting Inky display connectivity.

  Use this module to check if GPIO pins, SPI, and I2C/EEPROM are accessible
  before attempting to start an Inky display.

  ## Example

      case Inky.Doctor.check() do
        {:ok, results} ->
          IO.puts("All checks passed!")
          IO.inspect(results)

        {:error, failures} ->
          Enum.each(failures, fn {resource, error, hint} ->
            IO.puts("\#{resource}: \#{error}")
            IO.puts("  Hint: \#{hint}")
          end)
      end

  ## Running Individual Checks

      Inky.Doctor.check_gpio()
      Inky.Doctor.check_spi()
      Inky.Doctor.check_eeprom()
  """

  @default_pin_mappings %{
    busy_pin: 17,
    dc_pin: 22,
    reset_pin: 27,
    cs0_pin: 0
  }

  @spi_speed_hz 488_000

  @type check_result ::
          {:ok, %{gpio: map(), spi: map(), eeprom: map()}}
          | {:error, [failure()]}

  @type failure :: {atom(), atom(), String.t()}

  @doc """
  Run all diagnostic checks.

  ## Options

    * `:pin_mappings` - custom GPIO pin mappings (default: standard Inky pins)
    * `:gpio_mod` - GPIO module (default: Circuits.GPIO)
    * `:spi_mod` - SPI module (default: Circuits.SPI)
    * `:i2c_mod` - I2C module (default: Circuits.I2C)

  ## Returns

    * `{:ok, results}` - all checks passed with details
    * `{:error, failures}` - list of failures with hints
  """
  @spec check(keyword()) :: check_result()
  def check(opts \\ []) do
    gpio_result = check_gpio(opts)
    spi_result = check_spi(opts)
    eeprom_result = check_eeprom(opts)

    failures =
      collect_failures([
        {:gpio, gpio_result},
        {:spi, spi_result},
        {:eeprom, eeprom_result}
      ])

    case failures do
      [] ->
        {:ok,
         %{
           gpio: unwrap_ok(gpio_result),
           spi: unwrap_ok(spi_result),
           eeprom: unwrap_ok(eeprom_result)
         }}

      failures ->
        {:error, failures}
    end
  end

  @doc """
  Check if GPIO pins are accessible.

  Attempts to open each required GPIO pin and immediately closes it.

  ## Options

    * `:pin_mappings` - custom GPIO pin mappings
    * `:gpio_mod` - GPIO module (default: Circuits.GPIO)

  ## Returns

    * `{:ok, %{busy: {:ok, pin}, dc: {:ok, pin}, reset: {:ok, pin}}}` on success
    * `{:error, failures}` with list of failed pins and hints
  """
  @spec check_gpio(keyword()) :: {:ok, map()} | {:error, [failure()]}
  def check_gpio(opts \\ []) do
    gpio_mod = opts[:gpio_mod] || Circuits.GPIO
    pin_mappings = opts[:pin_mappings] || @default_pin_mappings

    pins = [
      {:busy, pin_mappings[:busy_pin], :input},
      {:dc, pin_mappings[:dc_pin], :output},
      {:reset, pin_mappings[:reset_pin], :output}
    ]

    results =
      Enum.map(pins, fn {name, pin, direction} ->
        {name, check_single_gpio(gpio_mod, pin, direction)}
      end)

    failures =
      results
      |> Enum.filter(fn {_name, result} -> match?({:error, _, _}, result) end)
      |> Enum.map(fn {name, {:error, error, hint}} ->
        {:"gpio_#{name}", error, hint}
      end)

    case failures do
      [] ->
        {:ok, Map.new(results, fn {name, {:ok, pin}} -> {name, {:ok, pin}} end)}

      failures ->
        {:error, failures}
    end
  end

  @doc """
  Check if SPI device is accessible.

  ## Options

    * `:pin_mappings` - custom pin mappings (uses cs0_pin for device path)
    * `:spi_mod` - SPI module (default: Circuits.SPI)

  ## Returns

    * `{:ok, %{device: "spidev0.X", status: :ok}}` on success
    * `{:error, :spi, error, hint}` on failure
  """
  @spec check_spi(keyword()) :: {:ok, map()} | {:error, atom(), String.t()}
  def check_spi(opts \\ []) do
    spi_mod = opts[:spi_mod] || Circuits.SPI
    pin_mappings = opts[:pin_mappings] || @default_pin_mappings
    cs_pin = pin_mappings[:cs0_pin]
    device = "spidev0.#{cs_pin}"

    case spi_mod.open(device, speed_hz: @spi_speed_hz) do
      {:ok, ref} ->
        spi_mod.close(ref)
        {:ok, %{device: device, status: :ok}}

      {:error, :enoent} ->
        {:error, :enoent, "SPI device /dev/#{device} not found. Enable SPI via raspi-config"}

      {:error, :eacces} ->
        {:error, :eacces, "Permission denied for /dev/#{device}. Add user to spi group"}

      {:error, reason} ->
        {:error, reason, "Failed to open SPI device /dev/#{device}: #{inspect(reason)}"}
    end
  end

  @doc """
  Check if EEPROM is readable and return display info.

  Note: EEPROM read may only work once per boot on some displays.

  ## Options

    * `:i2c_mod` - I2C module (default: Circuits.I2C)

  ## Returns

    * `{:ok, %{status: :ok, display_variant: "...", ...}}` on success
    * `{:ok, %{status: :skipped, reason: "..."}}` if I2C unavailable (non-fatal)
    * `{:error, error, hint}` on failure
  """
  @spec check_eeprom(keyword()) :: {:ok, map()} | {:error, atom(), String.t()}
  def check_eeprom(opts \\ []) do
    i2c_mod = opts[:i2c_mod] || Circuits.I2C

    case Inky.EEPROM.read(i2c_mod) do
      {:ok, eeprom} ->
        {:ok,
         %{
           status: :ok,
           width: eeprom.width,
           height: eeprom.height,
           color: eeprom.color,
           display_variant: eeprom.display_variant
         }}

      {:error, :enoent} ->
        {:ok, %{status: :skipped, reason: "I2C bus not found (EEPROM check is optional)"}}

      {:error, :eacces} ->
        {:error, :eacces, "Permission denied for I2C. Add user to i2c group"}

      {:error, {:invalid_data, _data}} ->
        {:error, :invalid_data, "EEPROM data invalid. Display may not have EEPROM"}

      {:error, reason} ->
        {:error, reason, "Failed to read EEPROM: #{inspect(reason)}"}
    end
  end

  # Private helpers

  defp check_single_gpio(gpio_mod, pin, direction) do
    case gpio_mod.open(pin, direction) do
      {:ok, ref} ->
        gpio_mod.close(ref)
        {:ok, pin}

      {:error, :export_failed} ->
        {:error, :export_failed,
         "GPIO #{pin} export failed. Run with sudo or add user to gpio group"}

      {:error, :eacces} ->
        {:error, :eacces, "Permission denied for GPIO #{pin}. Add user to gpio group"}

      {:error, reason} ->
        {:error, reason, "Failed to open GPIO #{pin}: #{inspect(reason)}"}
    end
  end

  defp collect_failures(results) do
    Enum.flat_map(results, fn
      {:gpio, {:error, failures}} -> failures
      {:spi, {:error, error, hint}} -> [{:spi, error, hint}]
      {:eeprom, {:error, error, hint}} -> [{:eeprom, error, hint}]
      _ -> []
    end)
  end

  defp unwrap_ok({:ok, value}), do: value
end
