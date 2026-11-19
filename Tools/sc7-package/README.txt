Switch Lite / T210B01 (Mariko) SC7 Suspend/Resume Candidate Package (ARM64)
===========================================================================

This directory contains the online package scripts and mocked transaction tests.
Place the scripts and Sc7Package.psm1 beside the signed payload directories when
assembling an online package. Firmware and kernel binaries are built separately.
Local component hashes and validation results are in
docs/hdh001-home/sc7-neon-validation-20261118.json in the WinX repository.

Contents
--------
1. firmware\bl31.bin
   - Switchroot/LineageOS T210B01 TF-A (85081cab2050051ea6e93206ef0f80bc0676e613)
     built with patches 0001..0011 and the --sc7 option.
       * Extended PSCI CPU_SUSPEND state IDs:
         - 0x40000007 (C7 core powerdown)
         - 0x40000010 (CC6 cluster idle)
         - 0x4000001B (SC7 SoC system suspend)
       * BPMP MRQ_ENABLE_SUSPEND with acknowledged cancellation and rollback;
         address checks for PMC_SCRATCH39 and PMC_SECURE_SCRATCH119
       * CAR PLL/clock/peripheral context save & restore across SC7
       * Pinmux + pad control context save & restore across SC7
2. firmware\bl31-default-stock.bin
   - Build the same patch chain without --sc7. The default BL31 image was
     byte-identical to the reviewed default image in the local build.
3. firmware\DsdtSc7.aml
   - Compiled ACPI DSDT (SWITCH_LITE_SLEEP=1 and SWITCH_LITE_PROCESSOR_IDLE=1) exposing \_SB.PEP0 (ACPI\SWOA0E01)
     and \_SB.PWRB PMC_CNTRL (0x7000E400) + GIC SPI 86 / GSI 118 (PMU_EXT) wake IRQ.
4. drivers\<name>\
   - Cross-built ARM64 Windows drivers (.sys + .inf):
     * tegra214pep   (0.2.0.0, DriverVersion 3) - Pure-WDM PoFx PEP (no WDFLDR)
     * switchpwrbtn  (1.0.0.5, DriverVersion 5) - Passive PMU_EXT wake IRQ + polling fallback
     * tegra210gpio  (1.0.0.5, DriverVersion 5) - 8-bank SC7 context save/restore
     * tegra210i2c   (1.0.0.6, DriverVersion 6) - 6-bus CAR + packet-mode SC7 restore
     * switchfan     (1.0.0.15, DriverVersion 15) - ScreenOffIdle timer park + GPU rail guard + PFM CSR fallback
     * switchbattery (1.0.0.13, DriverVersion 13) - Display-driven S0-idle D3 + IOCTL StopIdle
     * switchrtc     (1.0.0.3, DriverVersion 3) - SC7 wall-clock resync + SetSystemTime detach/reattach
     * switchtouch   (1.0.1.1, DriverVersion 6) - Display-driven S0-idle D3
     * switchsio     (0.2.4.0) - Display-driven S0-idle D3 + clean STM32 wake re-init
     * switchbt      (existing D0 UART/BCM4356 restore preserved)
     * tegraxusb     (0.1.1.0) - Stale Notified invalidation when XUSB loses power across SC7
   - Note: Tegra210Sdhc (nvtsdhc) SC7 CAR/SDHCI/DDR200 context restore (6563177 + 86f69ad)
     is already in the Windows-for-Switch-Drivers baseline and continues to build with the
     parent's local per-card winarm-target.h.
5. gpu\tegragpurender\
   - Cross-built ARM64 GM20B WDDM KMD (tegragpurender.sys) with bounded real-fence
     queue drain before D3, DVFS detach/park at 460.8 MHz / 800 mV, GPU VA/page-table
     preservation, and hardware-probed context retention vs power-loss epoch bump.
   - Merge mesa-sc7.diff into the active tgd3d driver package rather than installing
     standalone tegragpurender.inf over an active tgd3d UMD installation.

Hardware Prerequisites Before Enabling EnableSc7=1 (Owned by Parent)
--------------------------------------------------------------------
- All kernel binaries must be test-signed by the parent host workflow before installation.
- Hekate must supply compatible Mariko warmboot and BPMP firmware and reserve
  their memory. TF-A checks address shape and range in PMC_SECURE_SCRATCH119
  and PMC_SCRATCH39. Those register checks alone cannot verify image contents
  or retention. Firmware compatibility and sleep/wake still need board testing.
- EnableSc7 defaults to 0. The candidate remains a separate opt-in package.

Transaction, Retry, and Recovery Semantics
------------------------------------------
- Preflight before mutation: Install-Sc7Candidate-Online.ps1 validates every selected INF,
  its DriverVer, and all catalog/payload files referenced by the INF before modifying the
  registry, journal, or Driver Store.
- Safe gate ordering: If HKLM:\SYSTEM\CurrentControlSet\Services\tegra214pep (or its
  Parameters subkey) exists, EnableSc7 is cleared to 0 and read back before any pnputil
  call. The script never fabricates an orphan tegra214pep service key when PEP is absent;
  when -IncludePep installs tegra214pep, EnableSc7=0 is asserted immediately afterward.
- Journal & retryability: Progress, prior OEM bindings/versions, newly staged oem*.inf
  packages, and same-boot pending reboot state are persisted atomically (temp write +
  File.Replace with .bak) to:
    %ProgramData%\SwitchWoA\Sc7Package\transaction-journal.json
  (overrideable with -JournalPath). Retries and incremental re-runs (e.g., adding
  -IncludePep after base install) preserve original pre-SC7 prior bindings and pending
  reboot state across failures.
- Strict pnputil 259 handling: Exit code 259 (ERROR_NO_MORE_ITEMS) is accepted ONLY when
  independent Driver Store (version/date/provider/SHA256) and live PnP device-binding
  verification confirm that every matching present device is bound to the exact candidate
  package. Staging-only results (zero bound devices) and devices bound to newer/different
  packages fail and clean up any unreferenced newly-staged oem*.inf.
- Exit codes (Install-Sc7Candidate-Online.ps1 and Restore-PreSc7-Online.ps1):
    0    - Succeeded, no reboot required.
    3010 - Succeeded, reboot required (ERROR_SUCCESS_REBOOT_REQUIRED).
    3017 - Failed AND reboot required (ERROR_FAIL_REBOOT_REQUIRED).
    1    - Failed, no reboot required.
- Honest rollback (Restore-PreSc7-Online.ps1):
  1. Clears EnableSc7=0 (when the tegra214pep service/parameters key exists) and checks
     runtime EnableSc7Active. Because tegra214pep updates EnableSc7Active only on the next
     display state notification or reboot, Restore returns 3010 (or 3017 on error) whenever
     EnableSc7Active remains non-zero.
  2. Reverts only attributable driver changes from the journal in reverse install order.
     Unrelated later device changes are preserved untouched. Per-device DiRollbackDriver is
     attempted first; pnputil /delete-driver <oem> /uninstall (never /force) + prior OEM
     re-bind is used only if the package was newly staged by the transaction, zero unrelated
     devices or active components use it, and any prior OEM package still exists in the
     Driver Store. Shared or pre-existing OEM packages are never deleted.
  3. If a journal is missing or rollback is incomplete, inspect the journal and use Device
     Manager per-device rollback / driver selection, verify tgd3d UMD + 5s post-logon
     startup if standalone tegragpurender was installed, and revert firmware\bl31.bin to
     firmware\bl31-default-stock.bin and rebuild UEFI without -D SWITCH_LITE_SC7=1.
- Offline mock regression tests: run package\Test-Sc7Package.ps1 (uses temporary INF/payload
  files and an in-memory mock PnP/Driver Store/Registry context; never modifies real
  hardware or installs drivers).
