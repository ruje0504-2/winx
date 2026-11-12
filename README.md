<img width="1536" height="1024" alt="winx" src="https://github.com/user-attachments/assets/6c031e07-31b2-4030-8395-54d8e745d450" />

# WinX for Nintendo Switch Lite

Boot Windows 11 ARM64 from microSD on the **Nintendo Switch Lite (HDH-001, Tegra T214)**. On a prepared card, select **Windows 11 Lite** in Hekate. Windows 11 Home and a trimmed Pro installation both reached the desktop on build 22631.2861 (23H2).

## Hardware status

| Feature | Result on the tested Lite |
| --- | --- |
| microSD / SDR104 / DDR200 | Driver **0.5.0.3** boots Windows from the 80 GiB `WINARM` volume with FAT32 visible; the owner confirmed desktop boot. DDR200 automatic detection, tuning and SDR104 recovery are implemented. Active DDR200 mode and throughput still need runtime confirmation. [Storage status](https://github.com/ruje0504-2/Windows-for-Switch-Drivers/blob/hdh001-winarm-bounded-write/drivers/Tegra210Sdhc/README.md#t214-ddr200-candidate-0501) |
| Display and touch | Lite touch **1.0.1.2** is currently installed, with GPIO **1.0.0.4** and I²C **1.0.0.5**. The trimmed Pro desktop works in landscape; earlier FTM4 testing confirmed taps in Windows Setup. The current version inventory is not a new touch acceptance test. |
| Analog sticks and gamepad | SwitchSio **0.2.5.0** is currently installed. Windows previously detected the built-in HID gamepad/mouse and controller input. Both sticks are exposed through generic HID; in-game use awaits testing. |
| Desktop controls | Current installed package: **SwitchSio 0.2.5.0**. Left-stick pointer, ZR/ZL clicks, Capture desktop mode and **+** On-Screen Keyboard are the existing mapping. Right-stick scrolling, R3 middle click and D-pad arrows were added in 0.2.3; they have not been revalidated on 0.2.5.0. [Button mapping](https://github.com/ruje0504-2/Windows-for-Switch-Drivers/blob/hdh001-winarm-bounded-write/drivers/SwitchSensor/README.md) |
| 3D graphics | The experimental driver passed native Vulkan triangle readback and Tegra X1 Display-class Code 0 on the Lite. The standard Windows desktop uses software rendering. [GPU project](https://github.com/ruje0504-2/mesa-switch-woa) |
| Wi-Fi and Bluetooth | **Wi-Fi 0.5.7.0** is owner-confirmed usable after the SD update on November 12. SSH confirms `oem88.inf`, Code 0 and the exact installed SYS hash. It checks firmware disconnect state before failing the adapter for a missing event and records the leave phase. Repeated reconnects and sustained stability remain pending. **Bluetooth 1.0.0.19** is installed and was owner-confirmed working. [Wi-Fi evidence and references](https://github.com/ruje0504-2/Windows-for-Switch-Drivers/blob/hdh001-winarm-bounded-write/drivers/SwitchWifi/README.md) |
| Audio and backlight | **SwitchAudio 1.0.0.9** is installed. The built-in speakers play audio; brightness controls work on the internal panel. |
| Fan and clocks | **SwitchFan 1.0.0.12** is installed and hash-verified. Its thermal curve requests 32% PWM at 35 C, 75% at 40 C and 100% at 45 C. CPU readback was restored to the owner's requested **1996.8 MHz**; earlier RAM readback was 1866 MHz. Existing thermal throttling and screen-off policy are retained. [Cooling details](https://github.com/ruje0504-2/Windows-for-Switch-Drivers/blob/hdh001-winarm-bounded-write/drivers/SwitchFan/README.md) |
| Power button / S0 screen-off and wake | **SwitchPowerButton 1.0.0.6** is currently installed. The earlier repeated S0 screen-off/wake acceptance applies to **1.0.0.4**, still the default-branch source; this inventory does not validate the uncommitted 1.0.0.6 changes. SC7 deep sleep and S4 hibernation remain unsupported. [Default driver source](https://github.com/ruje0504-2/Windows-for-Switch-Drivers/tree/hdh001-winarm-bounded-write/drivers/SwitchPowerButton) |
| Shutdown and restart | Current Lite battery package: **SwitchBattery 1.0.0.11**, including the request-ownership fix introduced in 1.0.0.8. The owner previously confirmed normal shutdown and native restart. BL31 r8 returns Windows Restart to the captured Windows entry; a cold boot after shutdown opens Hekate. [Power status](docs/hdh001-home/power-performance.md) |
| Charge termination | SwitchBattery **1.0.0.11** enables BQ24193 automatic termination and an eight-hour safety timer while preserving existing charging limits. Live configuration readback passed; a full-charge/recharge cycle remains unverified. [Charging policy](docs/hdh001-home/power-performance.md#charge-termination) |

Package versions were read from the device on 2026-11-12. Installation is
separate from feature acceptance. Default-branch source remains Lite touch
1.0.1.0, SwitchSio 0.2.3.0 and SwitchPowerButton 1.0.0.4; the newer installed
test packages are identified above without claiming their source was promoted.
USB-C peripherals and headphones await hardware testing. [Porting status](docs/hdh001-home/PORTING.md)

Driver source is maintained in [Windows-for-Switch-Drivers](https://github.com/ruje0504-2/Windows-for-Switch-Drivers). The `WindowsDrivers` submodule pins the matching revision.

## Storage profiles

Both **WINARM only** and **WINARM + FAT32** are supported build profiles.
The current card exposes FAT32 using `--expose-fat32`. The latest owner
comparison found no clear responsiveness difference between the two views;
earlier reports of stalls do not establish a confirmed cause or a completed
performance fix. Hekate uses the physical FAT32 partition in either profile.

Build BL33 and the Windows SD driver from the same generated header whenever
you change the view. [Storage build instructions](docs/hdh001-home/README.md#firmware-build)

## Building and installing

Start with the [Stage 6 guide](docs/hdh001-home/README.md) to prepare the boot files and drivers. Use your own Windows ARM64 image and a compatible Switchroot BL31. Windows driver packages and their hardware results are in the [companion driver repository](https://github.com/ruje0504-2/Windows-for-Switch-Drivers).

## Credits

WinX builds on [NintendoSwitchPkg](https://github.com/steck0714/NintendoSwitchPkg) and [EDK II](https://github.com/tianocore/edk2), with the [Lumia950XLPkg](https://github.com/WOA-Project/Lumia950XLPkg) build workflow. Boot and board support draw on [Hekate](https://github.com/CTCaer/hekate), [Switchroot](https://switchroot.org/) and hayato41200’s [Windows-for-Switch firmware](https://github.com/hayato41200/Windows-for-Switch) and [drivers](https://github.com/hayato41200/Windows-for-Switch-Drivers). For the original T210/Erista port, see the [upstream WinX notes](README.winx.md). [License](LICENSE)
