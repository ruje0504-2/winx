#!/usr/bin/env python3
"""Exercise T210B01 SC7 validator, preflight checks, BPMP cancel, and GICv2 recovery."""
from pathlib import Path
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).resolve()
text = (source / "plat/nvidia/tegra/soc/t210/plat_psci_handlers.c").read_text()
start = text.index("int32_t tegra_soc_validate_power_state(")
end = text.index("\n}\n", start) + 3
validator = text[start:end]
assert "SWITCH_LITE_SC7" in validator, "Apply patch 0007 before running this test"

helper = (source / "plat/nvidia/tegra/soc/t210/t214/sc7.c").read_text()
helper = helper[helper.index("#define LITE_PMC_"):]

harness = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <bpmp.h>

#define MPIDR_AFFLVL0 0
#define MPIDR_AFFLVL1 1
#define PLAT_MAX_PWR_LVL 2
#define PLATFORM_MAX_CPUS_PER_CLUSTER 4
#define PSTATE_ID_CORE_POWERDN 7
#define PSTATE_ID_CLUSTER_IDLE 16
#define PSTATE_ID_SOC_POWERDN 27
#define PLAT_MAX_OFF_STATE 28
#define PLAT_SYS_SUSPEND_STATE_ID 27
#define PSCI_E_SUCCESS 0
#define PSCI_E_NOT_SUPPORTED -1
#define PSCI_E_INVALID_PARAMS -2
#define PSCI_E_DENIED -3
#define PMC_CONFIG 0
#define PMC_SCRATCH1 0x54U
#define PMC_SCRATCH39 0x138U
#define PMC_SECURE_SCRATCH119 0xB34U
#define TEGRA_DRAM_BASE UINT64_C(0x80000000)
#define ERROR(...) ((void)0)

/* PSCI_EXTENDED_STATE_ID := 1 encoding used by plat/nvidia/tegra/platform.mk */
#define PSTATE_VALID_MASK 0xB0000000U
#define PSTATE_TYPE_SHIFT 30
#define PSTATE_ID_MASK 0xfffffffU

typedef struct { uint8_t pwr_domain_state[3]; } psci_power_state_t;
typedef struct { uint64_t sc7entry_fw_base; uint64_t tzdram_base; } plat_params_from_bl2_t;

static plat_params_from_bl2_t params;
static int init_status, reply_status, init_calls, enable_reqs, cancel_reqs;
static bool b01;
static uint32_t pmc[0xC00 / 4];
static uint32_t gicd[0x1000 / 4];
static uint32_t gicd_banked[4][0x500 / 4];
static uint32_t gicc_banked[4][0x100 / 4];
static uint32_t sysctr0;
static unsigned pmc_writes, delays;
static bool wake_write_fault;
#if SWITCH_LITE_SC7
static unsigned current_cpu, flushes;
#endif

static const plat_params_from_bl2_t *bl31_get_plat_params(void) { return &params; }
static int psci_get_pstate_id(unsigned int state) { return (int)(state & PSTATE_ID_MASK); }
static int psci_validate_psci_pstate(unsigned int power_state) {
    if ((power_state & PSTATE_VALID_MASK) != 0U)
        return PSCI_E_INVALID_PARAMS;
    return PSCI_E_SUCCESS;
}

#if SWITCH_LITE_SC7
static bool tegra_chipid_is_t210_b01(void) { return b01; }
#endif

int tegra_bpmp_init(void) {
    init_calls++;
    return init_status;
}

int32_t tegra_bpmp_send_receive_atomic(int mrq, const void *out, int out_size,
                                       void *in, int in_size) {
    const uint32_t *words = out;
    assert(mrq == MRQ_ENABLE_SUSPEND && out_size == 8);
    assert(words[1] == 0U);
    assert(in != NULL && in_size == 0);
    if (words[0] == TEGRA_PM_SC7) {
        enable_reqs++;
        return reply_status;
    }
    assert(words[0] == 0U);
    cancel_reqs++;
    return 0;
}

#if SWITCH_LITE_SC7
static uint32_t *gic_reg(uintptr_t addr) {
    if (addr >= 0x50041000U && addr < 0x50042000U) {
        uint32_t off = (uint32_t)(addr - 0x50041000U);
        assert((off & 3U) == 0U);
        if (off == 0x080U || off == 0x100U || off == 0x180U ||
            (off >= 0x400U && off < 0x420U)) {
            return &gicd_banked[current_cpu][off / 4U];
        }
        return &gicd[off / 4U];
    }
    if (addr >= 0x50042000U && addr < 0x50042100U) {
        uint32_t off = (uint32_t)(addr - 0x50042000U);
        assert((off & 3U) == 0U);
        return &gicc_banked[current_cpu][off / 4U];
    }
    assert(addr == 0x7000f000U);
    return &sysctr0;
}

static uint32_t mmio_read_32(uintptr_t addr) {
    return *gic_reg(addr);
}

static void mmio_write_32(uintptr_t addr, uint32_t val) {
    if (addr >= 0x50041180U && addr < 0x500411a0U) {
        uint32_t off = (uint32_t)(addr - 0x50041000U);
        if (off == 0x180U) {
            gicd_banked[current_cpu][0x100U / 4U] &= ~val;
        } else {
            gicd[(off - 0x80U) / 4U] &= ~val;
        }
        return;
    }
    if (addr >= 0x50041100U && addr < 0x50041120U) {
        uint32_t off = (uint32_t)(addr - 0x50041000U);
        if (off == 0x100U) {
            gicd_banked[current_cpu][0x100U / 4U] |= val;
        } else {
            gicd[off / 4U] |= val;
        }
        return;
    }
    *gic_reg(addr) = val;
}

static uint32_t tegra_pmc_read_32(uint32_t offset) {
    assert(offset < sizeof(pmc) && (offset & 3U) == 0U);
    return pmc[offset / 4U];
}

static void tegra_pmc_write_32(uint32_t offset, uint32_t value) {
    assert(offset < sizeof(pmc) && (offset & 3U) == 0U);
    pmc_writes++;
    if (offset == 0x160U && wake_write_fault)
        return;
    if (offset == 0x168U) {
        assert(value == (1U << 19));
        pmc[offset / 4U] &= ~value;
    } else {
        pmc[offset / 4U] = value;
    }
}

static void udelay(unsigned int us) {
    assert(us == 120U);
    assert(delays < 2U);
    assert(!!(pmc[0] & (1U << 5)) == (delays == 0U));
    delays++;
}

static void dsbsy(void) {}
static void flush_dcache_range(uintptr_t addr, size_t size) {
    (void)addr;
    assert(size > 0U);
    flushes++;
}
#endif
'''

harness += "\n#if SWITCH_LITE_SC7\n" + helper + "\n#endif\n"
harness += validator
harness += r'''
static void setup_valid_board(void) {
    memset(pmc, 0, sizeof(pmc));
    memset(gicd, 0, sizeof(gicd));
    memset(gicd_banked, 0, sizeof(gicd_banked));
    memset(gicc_banked, 0, sizeof(gicc_banked));
    sysctr0 = 0;
    pmc[0] = 0x00020001U;           /* INTR_POLARITY | KBC_CLK_OE */
    pmc[0x0c / 4] = 0x13579U;
    pmc[0x10 / 4] = 0x24680U;
    pmc[0x14 / 4] = 0x5500U;
    params.tzdram_base = 0xFFF00000U;
    /* Hekate B01 handoff: SCRATCH1 may be zero; both entries are in DRAM. */
    pmc[PMC_SECURE_SCRATCH119 / 4] = 0xFFE3EC00U;
    pmc[PMC_SCRATCH39 / 4] = 0xFFE00040U;
    pmc[0x160 / 4] = 0x12345U;
    pmc[0x164 / 4] = 0x87654U;
    pmc[0x168 / 4] = (1U << 19) | 0x80U;

    /* Arm GIC Group 1 INTID 118 (word 3, bit 22) as Windows SwitchPowerButton does. */
    gicd[0x000 / 4] = 0x3U;
    gicd[0x004 / 4] = 0x6U; /* ITLinesNumber = 6 -> 224 interrupts (7 words) */
    gicd[0x080 / 4 + 3] = ~(1U << 5); /* All Group 1 except secure SPI bit 5 */
    gicd[0x100 / 4 + 3] = (1U << 22) | 0x000000ffU;
    gicd[0x400 / 4 + 25] = 0x90901090U; /* Byte 1 is secure SPI bit 5 */
    gicd[0x400 / 4 + 29] = 0xa0a080a0U;
    gicd[0x800 / 4 + 29] = 0x01010101U;
    gicd[0xc00 / 4 + 6] = 0x55555555U;
    gicd[0xc00 / 4 + 7] = 0x55555555U;

    for (unsigned c = 0; c < 4; c++) {
        gicd_banked[c][0x080 / 4] = 0xffff00ffU;
        gicd_banked[c][0x100 / 4] = 0x4000ffffU; /* PPI 30 + SGIs */
        for (unsigned i = 0; i < 8; i++)
            gicd_banked[c][0x400 / 4 + i] = 0x80808080U ^ (c << 8) ^ i;
        gicc_banked[c][0x000 / 4] = 0x263U; /* EnableGrp0|Grp1|FIQEn|EOImodeNS */
        gicc_banked[c][0x004 / 4] = 0xf8U;
        gicc_banked[c][0x00c / 4] = 0x03U;
    }
}

static void run(unsigned int state, int expected, unsigned expected_reqs) {
    psci_power_state_t out = { { 0, 0, 0 } }, before = out;
    enable_reqs = cancel_reqs = init_calls = pmc_writes = delays = 0;
    if (psci_validate_psci_pstate(state) != PSCI_E_SUCCESS) {
        assert(expected == PSCI_E_INVALID_PARAMS);
        return;
    }
    assert(tegra_soc_validate_power_state(state, &out) == expected);
    assert(enable_reqs == (int)expected_reqs);
    if (expected_reqs && reply_status == 0 && expected == 0) {
        assert(delays == 2U);
        assert(pmc[0x3c / 4] == 0x6c00U);
        assert(pmc[0xe0 / 4] == 0x5a8U);
        assert(pmc[0xc8 / 4] == 0U && pmc[0xcc / 4] == 0U);
        assert((pmc[0] & ((1U << 9) | (1U << 11) | (1U << 16) | (1U << 17))) ==
               ((1U << 9) | (1U << 11) | (1U << 16) | (1U << 17)));
        assert((pmc[0] & ((1U << 8) | (1U << 10) | (1U << 14) | (1U << 15))) == 0U);
        assert(pmc[0x168 / 4] == 0x80U);
        assert(pmc[0x164 / 4] == (0x87654U & ~(1U << 19)));
        assert(pmc[0x160 / 4] == 0x92345U);
    }
    if (expected != 0) {
        assert(memcmp(&out, &before, sizeof(out)) == 0);
    }
}

int main(void) {
    const unsigned c7 = (1U << PSTATE_TYPE_SHIFT) | PSTATE_ID_CORE_POWERDN;   /* 0x40000007 */
    const unsigned cc6 = (1U << PSTATE_TYPE_SHIFT) | PSTATE_ID_CLUSTER_IDLE;  /* 0x40000010 */
    const unsigned sc7 = (1U << PSTATE_TYPE_SHIFT) | PSTATE_ID_SOC_POWERDN;   /* 0x4000001B */

    /* Legacy state IDs with bits [29:28] or [25:24] set are rejected by extended PSCI! */
    assert(psci_validate_psci_pstate(0x01010010U) == PSCI_E_SUCCESS); /* bit 24 ok, bit 28 bad */
    assert(psci_validate_psci_pstate(0x10000007U) == PSCI_E_INVALID_PARAMS);

    (void)b01;
    (void)sysctr0;
    (void)wake_write_fault;
    b01 = true;
    setup_valid_board();
    run(c7, 0, 0);
    run(cc6, 0, 0);
    run(0x400000ffU, PSCI_E_INVALID_PARAMS, 0);
    run(sc7, 0, SWITCH_LITE_SC7);

#if SWITCH_LITE_SC7
    /* Downgrade cancellation revokes MRQ_ENABLE_SUSPEND(TEGRA_PM_SC7, 0). */
    tegra_lite_sc7_cancel();
    assert(cancel_reqs == 1);
    tegra_lite_sc7_cancel();
    assert(cancel_reqs == 1); /* idempotent once cancelled */

    /* Erista SCRATCH1 cannot substitute for Mariko SECURE_SCRATCH119. */
    setup_valid_board();
    pmc[PMC_SCRATCH1 / 4] = 0x80010000U;
    pmc[PMC_SECURE_SCRATCH119 / 4] = 0;
    run(sc7, PSCI_E_NOT_SUPPORTED, 0);
    const uint32_t invalid_entries[] = {0U, 0x4003e000U, 0x7ffffffcU,
                                       0xFFF00000U, 0xFFFFFFFCU, 0xFFE00041U};
    for (unsigned i = 0; i < sizeof(invalid_entries) / sizeof(invalid_entries[0]); i++) {
        setup_valid_board();
        pmc[PMC_SECURE_SCRATCH119 / 4] = invalid_entries[i];
        run(sc7, PSCI_E_NOT_SUPPORTED, 0);
        setup_valid_board();
        pmc[PMC_SCRATCH39 / 4] = invalid_entries[i];
        run(sc7, PSCI_E_NOT_SUPPORTED, 0);
    }

    /* Unarmed GIC INTID 118 (disabled or Group 0) must reject SC7 with DENIED. */
    setup_valid_board();
    gicd[0x100 / 4 + 3] &= ~(1U << 22);
    run(sc7, PSCI_E_DENIED, 0);
    setup_valid_board();
    gicd[0x080 / 4 + 3] &= ~(1U << 22);
    run(sc7, PSCI_E_DENIED, 0);

    /* Test GICv2 per-CPU + distributor save, SC7 hardware wipe, and restore! */
    setup_valid_board();
    for (unsigned c = 0; c < 4; c++) {
        current_cpu = c;
        tegra_lite_gic_pcpu_save(c);
    }
    /* CPU 3 goes offline via CPU_OFF: its banked snapshot must be invalidated. */
    tegra_lite_gic_pcpu_invalidate(3);
    current_cpu = 0;
    tegra_lite_gic_dist_save();

    /* Simulate SC7 power loss + TF-A gicv2_distif_init() / gicv2_cpuif_enable() wipe! */
    memset(gicd, 0, sizeof(gicd));
    memset(gicd_banked, 0, sizeof(gicd_banked));
    memset(gicc_banked, 0, sizeof(gicc_banked));
    pmc[0] = 0;
    sysctr0 = 0;
    gicd[0x000 / 4] = 0x1U; /* Only EnableGrp0 set by TF-A */
    gicd[0x004 / 4] = 0x6U;
    for (unsigned w = 1; w < 7; w++)
        gicd[0x080 / 4 + w] = ~0U; /* gicv2_distif_init marks non-secure SPIs Group 1 */
    gicd[0x080 / 4 + 3] &= ~(1U << 5); /* Secure Group 0 SPI must stay Group 0! */
    gicd[0x400 / 4 + 25] = 0x00002000U; /* TF-A sets secure SPI priority 0x20 */
    for (unsigned c = 0; c < 4; c++)
        gicc_banked[c][0x000 / 4] = 0x209U; /* EnableGrp1 wiped by TF-A! */

    current_cpu = 0;
    tegra_lite_gic_dist_restore();
    assert((pmc[0] & (1U << 17)) != 0U);
    assert((sysctr0 & 0x3U) == 0x3U);
    assert((gicd[0x000 / 4] & 0x3U) == 0x3U);
    assert((gicd[0x080 / 4 + 3] & (1U << 22)) != 0U);
    assert((gicd[0x080 / 4 + 3] & (1U << 5)) == 0U); /* Secure SPI preserved! */
    assert(gicd[0x400 / 4 + 25] == 0x90902090U); /* Secure byte 0x20 untouched! */
    assert((gicd[0x100 / 4 + 3] & (1U << 22)) != 0U);
    assert(gicd[0x400 / 4 + 29] == 0xa0a080a0U);
    assert(gicd[0x800 / 4 + 29] == 0x01010101U);
    assert(gicd[0xc00 / 4 + 7] == 0x55555555U);

    for (unsigned c = 0; c < 3; c++) {
        current_cpu = c;
        tegra_lite_gic_pcpu_restore(c);
        assert((gicc_banked[c][0x000 / 4] & 0x202U) == 0x202U);
        assert(gicc_banked[c][0x004 / 4] == 0xf8U);
        assert((gicd_banked[c][0x100 / 4] & 0xffff00ffU) == 0x400000ffU);
        assert((gicd_banked[c][0x100 / 4] & 0x0000ff00U) == 0U); /* Secure SGIs untouched! */
    }
    /* Invalidated CPU 3 must not restore stale banked state. */
    current_cpu = 3;
    tegra_lite_gic_pcpu_restore(3);
    assert((gicc_banked[3][0x000 / 4] & 0x2U) == 0U);
#endif

    setup_valid_board();
    reply_status = -110;
    run(sc7, SWITCH_LITE_SC7 ? PSCI_E_DENIED : 0, SWITCH_LITE_SC7);
    setup_valid_board();
    reply_status = 0;
    wake_write_fault = true;
    run(sc7, SWITCH_LITE_SC7 ? PSCI_E_DENIED : 0, SWITCH_LITE_SC7);
    assert(cancel_reqs == (SWITCH_LITE_SC7 ? 1 : 0));
    wake_write_fault = false;

    setup_valid_board();
    init_status = -1;
    run(sc7, PSCI_E_NOT_SUPPORTED, 0);
    params.sc7entry_fw_base = 0x80000000U;
    run(sc7, SWITCH_LITE_SC7 ? PSCI_E_NOT_SUPPORTED : 0, 0);

    b01 = false;
    run(sc7, 0, 0);
    params.sc7entry_fw_base = 0;
    run(sc7, PSCI_E_NOT_SUPPORTED, 0);
    init_status = 0;
    run(sc7, 0, 0);
    puts("PASS: extended PSCI IDs, SC7 preflight, BPMP ack/cancel, NX PMC timers, and GICv2 Group 1 restore");
    return 0;
}
'''

with tempfile.TemporaryDirectory(prefix="lite-sc7-") as temporary:
    directory = Path(temporary)
    c = directory / "test.c"
    c.write_text(harness)
    for enabled in (0, 1):
        binary = directory / f"test-{enabled}"
        subprocess.run([
            "cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
            "-fsanitize=address,undefined", f"-DSWITCH_LITE_SC7={enabled}",
            "-I", str(source / "plat/nvidia/tegra/include/drivers"),
            str(c), "-o", str(binary),
        ], check=True)
        subprocess.run([str(binary)], check=True)
