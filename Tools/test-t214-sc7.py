#!/usr/bin/env python3
"""Exercise T210B01 SC7 validator, preflight checks, BPMP cancel, and GICv2 recovery."""
from pathlib import Path
import subprocess
import sys
import tempfile

def extract_func(text: str, signature: str) -> str:
    start = text.index(signature)
    end = text.index("\n}\n", start) + 3
    return text[start:end]

source = Path(sys.argv[1]).resolve()
handlers_text = (source / "plat/nvidia/tegra/soc/t210/plat_psci_handlers.c").read_text()
pm_text = (source / "plat/nvidia/tegra/common/tegra_pm.c").read_text()
clocks_text = (source / "plat/nvidia/tegra/soc/t210/t214/clocks.c").read_text()

validator = extract_func(handlers_text, "int32_t tegra_soc_validate_power_state(")
assert "SWITCH_LITE_SC7" in validator, "Apply patch 0007 before running this test"

clocks_cclk = "\n".join([
    extract_func(clocks_text, "static bool cclk_policy_is_open_loop("),
    extract_func(clocks_text, "static bool cclk_policy_uses_pllx("),
    extract_func(clocks_text, "bool tegra_lite_clocks_cclk_supported("),
])

helper = (source / "plat/nvidia/tegra/soc/t210/t214/sc7.c").read_text()
helper = helper[helper.index("#define LITE_PMC_"):]

lite_handler_helpers = "\n".join([
    extract_func(handlers_text, "static int tegra_lite_bpmp_init_locked("),
    extract_func(handlers_text, "static bool tegra_lite_fc_wake_pending("),
    extract_func(handlers_text, "static bool tegra_lite_dfll_active("),
    extract_func(handlers_text, "static void tegra_lite_sc7_unlock_pgexit("),
])

handlers = "\n".join([
    validator,
    extract_func(handlers_text, "plat_local_state_t tegra_soc_get_target_pwr_state("),
    extract_func(handlers_text, "int tegra_soc_pwr_domain_suspend("),
    extract_func(handlers_text, "int tegra_soc_pwr_domain_power_down_wfi("),
    extract_func(handlers_text, "int tegra_soc_pwr_domain_on_finish("),
    extract_func(handlers_text, "int tegra_soc_pwr_domain_on("),
    extract_func(handlers_text, "int tegra_soc_pwr_domain_off("),
])

pm_ops = "\n".join([
    extract_func(pm_text, "static void tegra_pwr_domain_off("),
    extract_func(pm_text, "static void tegra_pwr_domain_suspend("),
    extract_func(pm_text, "static __dead2 void tegra_pwr_domain_power_down_wfi("),
    extract_func(pm_text, "static void tegra_pwr_domain_on_finish("),
])

harness = r'''
#include <assert.h>
#include <setjmp.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <bpmp.h>

#define MPIDR_AFFLVL0 0U
#define MPIDR_AFFLVL1 1U
#define MPIDR_AFFLVL2 2U
#define MPIDR_CPU_MASK 0xffU
#define PLAT_MAX_PWR_LVL 2U
#define PLATFORM_MAX_CPUS_PER_CLUSTER 4
#define PSCI_LOCAL_STATE_RUN 0U
#define PSTATE_ID_CORE_POWERDN 7U
#define PSTATE_ID_CLUSTER_IDLE 16U
#define PSTATE_ID_SOC_POWERDN 27U
#define PLAT_MAX_OFF_STATE 28U
#define PLAT_SYS_SUSPEND_STATE_ID 27U
#define PSCI_E_SUCCESS 0
#define PSCI_E_NOT_SUPPORTED -1
#define PSCI_E_INVALID_PARAMS -2
#define PSCI_E_DENIED -3
#define PSCI_E_INTERN_FAIL -6
#define PMC_CONFIG 0U
#define PMC_PWRGATE_STATUS 0x38U
#define PMC_SCRATCH1 0x54U
#define PMC_SCRATCH39 0x138U
#define PMC_SECURE_SCRATCH119 0xB34U
#define TEGRA_DRAM_BASE UINT64_C(0x80000000)
#define TEGRA_CAR_RESET_BASE 0x60006000U
#define TEGRA_CL_DVFS_BASE 0x70110000U
#define TEGRA_MSELECT_BASE 0x50060000U
#define TEGRA_MISC_BASE 0x70000000U
#define TEGRA_RES_SEMA_BASE 0x60001000U
#define TEGRA_IRAM_BASE 0x40000000U
#define TEGRA_IRAM_A_SIZE 0x10000U
#define SC7ENTRY_FW_HEADER_SIZE_BYTES 0U
#define CPU_CMPLX_RESET_CLR 0x454U
#define CPU_CORE_RESET_MASK 0x10001U
#define DVFS_DFLL_CTRL 0x0U
#define DVFS_DFLL_OUTPUT_CFG 0x20U
#define DFLL_OUTPUT_CFG_CLK_EN_BIT (1U << 24)
#define ENABLE_OPEN_LOOP 1U
#define ENABLE_CLOSED_LOOP 2U
#define PINMUX_AUX_DVFS_PWM 0x3184U
#define PINMUX_PWM_TRISTATE (1U << 4)
#define MSELECT_CONFIG 0x0U
#define ENABLE_UNSUP_TX_ERRORS (1U << 28)
#define ENABLE_WRAP_TO_INCR_BURSTS (1U << 29)
#define APB_SLAVE_SECURITY_ENABLE 0xc00U
#define PMC_SECURITY_EN_BIT (1U << 13)
#define TEGRA_BOND_OUT_U 0x7cU
#define TEGRA_BOND_OUT_H 0x78U
#define IRAM_B_LOCK_BIT (1U << 1)
#define IRAM_C_LOCK_BIT (1U << 2)
#define IRAM_D_LOCK_BIT (1U << 3)
#define APB_DMA_LOCK_BIT (1U << 2)
#define AHB_DMA_LOCK_BIT (1U << 1)
#define STA_OFFSET 0x0U
#define FLOWCTRL_FC_SEQ_INTERCEPT 0x5cU
#define INTERCEPT_IRQ_PENDING 0xffU
#define CORTEX_A57_L2_ECC_PARITY_PROTECTION_BIT (1U << 21)
#define TEGRA_PLAT_SC7_NO_BASE_RESTRICTION (1U << 0)
#define TEGRA_PLAT_PMC_NON_SECURE (1U << 1)
#define CONSOLE_FLAG_RUNTIME 1U
#ifndef __dead2
#define __dead2 __attribute__((__noreturn__))
#endif
#define ERROR(...) ((void)0)
#define INFO(...) ((void)0)

/* PSCI_EXTENDED_STATE_ID := 1 encoding used by plat/nvidia/tegra/platform.mk */
#define PSTATE_VALID_MASK 0xB0000000U
#define PSTATE_TYPE_SHIFT 30
#define PSTATE_ID_MASK 0xfffffffU

typedef uint64_t u_register_t;
typedef uint8_t plat_local_state_t;
typedef struct { plat_local_state_t pwr_domain_state[3]; } psci_power_state_t;
typedef struct {
    uint64_t sc7entry_fw_base;
    uint64_t sc7entry_fw_size;
    uint64_t r2p_payload_base;
    uint64_t tzdram_base;
    uint64_t tzdram_size;
    uint64_t flags;
    uint8_t uart_id;
    uint8_t l2_ecc_parity_prot_dis;
} plat_params_from_bl2_t;

static plat_params_from_bl2_t params;
static int init_status, reply_status, cancel_reply_status, init_calls, enable_reqs, cancel_reqs, do_idle_reqs;
static int se_suspend_status;
static bool b01, ccx_allowed = true, bpmp_timeout_unanswered;
static uint32_t pmc[0xC00 / 4];
static uint32_t gicd[0x1000 / 4];
static uint32_t gicd_banked[4][0x500 / 4];
static uint32_t gicc_banked[4][0x100 / 4];
static uint32_t car[0x800 / 4];
static uint32_t dfll[0x100 / 4];
static uint32_t sysctr0, mselect_cfg, misc_apb_sec, misc_dvfs_pwm, res_sema;
static u_register_t l2ctlr;
static unsigned current_cpu, pmc_writes, dfll_ctrl_reads;
static bool cpu_hw_on[PLATFORM_MAX_CPUS_PER_CLUSTER];
static int pgexit_lock_depth;
static bool cancel_while_pgexit_locked;
static jmp_buf wfi_jmp;
static bool wfi_jmp_active;
static unsigned wfi_calls, panic_calls, console_off_calls;
static unsigned gic_init_calls, gic_pcpu_init_calls, gic_cpuif_deact_calls;
static unsigned se_suspend_calls, se_save_tzram_calls, se_resume_calls;
static unsigned bpmp_suspend_calls, bpmp_resume_calls;
static unsigned fc_cpu_powerdn_calls, fc_soc_powerdn_calls, fc_cpu_off_calls;
static unsigned fc_cluster_idle_calls, fc_lock_cluster_calls;
static unsigned pmc_resume_calls, pmc_cpu_on_calls, fc_cpu_on_calls;
static uint32_t woken_mask;

static int cpu_powergate_mask[PLATFORM_MAX_CPUS_PER_CLUSTER];
static bool tegra_bpmp_available = true;

#if SWITCH_LITE_SC7
#define CB(n) (1U << (n))
#define PLL_ON CB(30)
#define CCLK_POLICY_CLKM 0x20000000U
#define CCLK_POLICY_PLLX 0x20008888U
#define CCLK_POLICY_SRC_CLKM 0x0U
#define CCLK_POLICY_SRC_PLLX 0x8U
#define CCLK_POLICY_RESERVED_MASK 0x0fff0000U
#define CAR_RST_DEV_W 0x35cU
#define CAR_CLK_OUT_ENB_W 0x364U
#define CAR_DVFS_BIT (1U << 27)

static struct {
    uint8_t suspended;
} __attribute__((aligned(64))) cpu_c7_suspended[PLATFORM_MAX_CPUS_PER_CLUSTER];
static bool sc7_pgexit_locked __attribute__((aligned(64)));
typedef struct { volatile uint32_t lock; } spinlock_t;
static spinlock_t lite_bpmp_lock;
static int lite_bpmp_init_status;
static bool lite_bpmp_init_done;
static uint32_t fc_seq_intercept;
static bool inject_fc_wake_in_delay;
static unsigned flushes, delays;
static u_register_t isr_el1;
static uint32_t pmc_write_counts[0xC00 / 4];
static uint32_t pmc_config_ro_mask;
static bool wake_write_fault;
static bool inject_wake_in_delay, sticky_wake_status;
static bool clocks_valid, pads_valid;
static unsigned clocks_save_calls, clocks_invalidate_calls, clocks_restore_calls;
static unsigned pads_save_calls, pads_restore_calls;
static unsigned secondary_setup_calls, runtime_setup_calls, fiq_route_calls, clear_reset_calls;
static void spin_lock(spinlock_t *l) { assert(l->lock == 0U); l->lock = 1U; }
static void spin_unlock(spinlock_t *l) { assert(l->lock == 1U); l->lock = 0U; }
static uint32_t tegra_fc_read_32(uint32_t off) {
    assert(off == FLOWCTRL_FC_SEQ_INTERCEPT);
    return fc_seq_intercept;
}
#endif

static const plat_params_from_bl2_t *bl31_get_plat_params(void) { return &params; }
static int psci_get_pstate_id(unsigned int state) { return (int)(state & PSTATE_ID_MASK); }
static int psci_validate_psci_pstate(unsigned int power_state) {
    if ((power_state & PSTATE_VALID_MASK) != 0U)
        return PSCI_E_INVALID_PARAMS;
    return PSCI_E_SUCCESS;
}
static unsigned int plat_my_core_pos(void) { return current_cpu; }
static u_register_t read_mpidr(void) { return (u_register_t)current_cpu; }
static bool tegra_chipid_is_t210_b01(void) { return b01; }
static u_register_t read_l2ctlr_el1(void) { return l2ctlr; }
static void write_l2ctlr_el1(u_register_t v) { l2ctlr = v; }
static void zeromem(void *mem, size_t length) { memset(mem, 0, length); }

int tegra_bpmp_init(void) {
    init_calls++;
    return init_status;
}

int32_t tegra_bpmp_send_receive_atomic(int mrq, const void *out, int out_size,
                                       void *in, int in_size) {
    const uint32_t *words = out;
    if (mrq == MRQ_DO_IDLE) {
        assert(out_size == 12 && in != NULL && in_size == 4);
        do_idle_reqs++;
        *(uint32_t *)in = BPMP_CCx_ALLOWED;
        return 0;
    }
    assert(mrq == MRQ_ENABLE_SUSPEND && out_size == 8);
    assert(words[1] == 0U);
    assert(in != NULL && in_size == 0);
    if (((res_sema & 0xff000000U) == (SIGN_OF_LIFE & 0xff000000U)) &&
        ((res_sema & CH_MASK(current_cpu)) != MA_FREE(current_cpu))) {
        return -110;
    }
    if (words[0] == TEGRA_PM_SC7) {
        enable_reqs++;
        if (reply_status != 0 && bpmp_timeout_unanswered)
            res_sema &= ~CH_MASK(current_cpu);
        return reply_status;
    }
    assert(words[0] == 0U);
    cancel_reqs++;
    cancel_while_pgexit_locked = (pgexit_lock_depth == 1);
    if (cancel_reply_status != 0 && bpmp_timeout_unanswered)
        res_sema &= ~CH_MASK(current_cpu);
    return cancel_reply_status;
}

static uint32_t *reg_ptr(uintptr_t addr) {
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
    if (addr >= TEGRA_CAR_RESET_BASE && addr < TEGRA_CAR_RESET_BASE + 0x800U) {
        uint32_t off = (uint32_t)(addr - TEGRA_CAR_RESET_BASE);
        assert((off & 3U) == 0U);
        return &car[off / 4U];
    }
    if (addr >= TEGRA_CL_DVFS_BASE && addr < TEGRA_CL_DVFS_BASE + 0x100U) {
        uint32_t off = (uint32_t)(addr - TEGRA_CL_DVFS_BASE);
        assert((off & 3U) == 0U);
        return &dfll[off / 4U];
    }
    if (addr == TEGRA_MSELECT_BASE + MSELECT_CONFIG)
        return &mselect_cfg;
    if (addr == TEGRA_MISC_BASE + APB_SLAVE_SECURITY_ENABLE)
        return &misc_apb_sec;
    if (addr == TEGRA_MISC_BASE + PINMUX_AUX_DVFS_PWM)
        return &misc_dvfs_pwm;
    if (addr == TEGRA_RES_SEMA_BASE + STA_OFFSET)
        return &res_sema;
    assert(addr == 0x7000f000U);
    return &sysctr0;
}

static uint32_t mmio_read_32(uintptr_t addr) {
    if (addr == TEGRA_CL_DVFS_BASE + DVFS_DFLL_CTRL)
        dfll_ctrl_reads++;
    return *reg_ptr(addr);
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
    *reg_ptr(addr) = val;
}

static uint32_t tegra_pmc_read_32(uint32_t offset) {
    assert(offset < sizeof(pmc) && (offset & 3U) == 0U);
    return pmc[offset / 4U];
}

static bool tegra_pmc_is_last_on_cpu(void) {
    if (!cpu_hw_on[current_cpu])
        return false;
    for (unsigned i = 0; i < PLATFORM_MAX_CPUS_PER_CLUSTER; i++) {
        if (i != current_cpu && cpu_hw_on[i])
            return false;
    }
    return true;
}

static bool tegra_fc_is_ccx_allowed(void) { return ccx_allowed; }
static void tegra_fc_ccplex_pgexit_lock(void) {
    assert(pgexit_lock_depth == 0);
    pgexit_lock_depth++;
}
static void tegra_fc_ccplex_pgexit_unlock(void) {
    assert(pgexit_lock_depth == 1);
    pgexit_lock_depth--;
}
static void plat_enable_console(uint8_t uart_id) { (void)uart_id; }
static void console_flush(void) {}
static void console_switch_state(unsigned int state) {
    if (state == 0U)
        console_off_calls++;
}
static __dead2 void wfi(void) {
    wfi_calls++;
    assert(wfi_jmp_active);
    longjmp(wfi_jmp, 1);
}
static __dead2 void panic(void) {
    panic_calls++;
    if (wfi_jmp_active)
        longjmp(wfi_jmp, 2);
    assert(0 && "unexpected panic");
    abort();
}
static void tegra_gic_init(void) { gic_init_calls++; }
static void tegra_gic_pcpu_init(void) { gic_pcpu_init_calls++; }
static void tegra_gic_cpuif_deactivate(void) { gic_cpuif_deact_calls++; }
static void tegra_memctrl_restore_settings(void) {}
static void tegra_memctrl_tzdram_setup(uint64_t base, uint64_t size) {
    (void)base;
    (void)size;
}
static void tegra_soc_cpu_prepare_pmic(void) {}
static void tegra_reset_all_dma_masters(void) {}
static int tegra_se_suspend(void) {
    se_suspend_calls++;
    return se_suspend_status;
}
static void tegra_se_save_tzram(void) { se_save_tzram_calls++; }
static void tegra_se_resume(void) { se_resume_calls++; }
void tegra_bpmp_suspend(void) { bpmp_suspend_calls++; }
void tegra_bpmp_resume(void) { bpmp_resume_calls++; }
static void tegra_fc_cluster_idle(u_register_t mpidr) {
    fc_cluster_idle_calls++;
    cpu_hw_on[mpidr & MPIDR_CPU_MASK] = false;
}
static void tegra_fc_cpu_powerdn(u_register_t mpidr) {
    unsigned cpu = (unsigned)(mpidr & MPIDR_CPU_MASK);
    assert(cpu == current_cpu);
    fc_cpu_powerdn_calls++;
    cpu_hw_on[cpu] = false;
}
static void tegra_fc_soc_powerdn(u_register_t mpidr) {
    assert((mpidr & MPIDR_CPU_MASK) == current_cpu);
    fc_soc_powerdn_calls++;
    for (unsigned i = 0; i < PLATFORM_MAX_CPUS_PER_CLUSTER; i++)
        cpu_hw_on[i] = false;
    pgexit_lock_depth = 0;
    pmc[PMC_PWRGATE_STATUS / 4U] = (1U << 14);
}
static void tegra_fc_bpmp_off(void) {}
static void tegra_fc_bpmp_on(uint32_t entry) { (void)entry; }
static void tegra_fc_lock_active_cluster(void) { fc_lock_cluster_calls++; }
static void tegra_pmc_lock_cpu_vectors(void) {}
static void plat_secure_cpu_vectors(bool sec) { (void)sec; }
static void tegra_pmc_resume(void) {
    assert(woken_mask == 0U);
    pmc_resume_calls++;
}
static void tegra_pmc_cpu_on(int cpu) {
    assert(fc_lock_cluster_calls > 0U);
    pmc_cpu_on_calls++;
    cpu_hw_on[cpu] = true;
    woken_mask |= 1U << (unsigned)cpu;
}
static void tegra_fc_cpu_on(int cpu) {
    assert(fc_lock_cluster_calls > 0U);
    fc_cpu_on_calls++;
    cpu_hw_on[cpu] = true;
    woken_mask |= 1U << (unsigned)cpu;
}
static void tegra_fc_cpu_off(int cpu) {
    fc_cpu_off_calls++;
    cpu_hw_on[cpu] = false;
}

#if SWITCH_LITE_SC7
static u_register_t read_isr_el1(void) { return isr_el1; }
static uint32_t cr(uint32_t offset) { return mmio_read_32(TEGRA_CAR_RESET_BASE + offset); }

static void tegra_pmc_write_32(uint32_t offset, uint32_t value) {
    assert(offset < sizeof(pmc) && (offset & 3U) == 0U);
    pmc_writes++;
    pmc_write_counts[offset / 4U]++;
    if (offset == PMC_CONFIG && pmc_config_ro_mask != 0U) {
        uint32_t cur = pmc[offset / 4U];
        pmc[offset / 4U] = (cur & pmc_config_ro_mask) |
                           (value & ~pmc_config_ro_mask);
        return;
    }
    if (offset == 0x160U && wake_write_fault)
        return;
    if (offset == 0x168U) {
        assert(value == (1U << 19));
        if (!sticky_wake_status)
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
    if (inject_wake_in_delay && delays == 2U)
        isr_el1 = (1U << 7);
    if (inject_fc_wake_in_delay && delays == 2U)
        fc_seq_intercept = (1U << 4); /* INTERRUPT_PENDING_CORE1 */
}

static void dsbsy(void) {}
static void flush_dcache_range(uintptr_t addr, size_t size) {
    (void)addr;
    assert(size > 0U);
    flushes++;
}

static void tegra_lite_clocks_save(void) {
    clocks_save_calls++;
    clocks_valid = true;
}
static void tegra_lite_clocks_invalidate(void) {
    clocks_invalidate_calls++;
    clocks_valid = false;
}
static int32_t tegra_lite_clocks_restore(void) {
    clocks_restore_calls++;
    if (!clocks_valid)
        return PSCI_E_DENIED;
    clocks_valid = false;
    return PSCI_E_SUCCESS;
}
static void tegra_lite_pads_save(void) {
    pads_save_calls++;
    pads_valid = true;
}
static int32_t tegra_lite_pads_restore(void) {
    pads_restore_calls++;
    if (!pads_valid)
        return PSCI_E_DENIED;
    pads_valid = false;
    return PSCI_E_SUCCESS;
}
static void plat_secondary_setup(void) { secondary_setup_calls++; }
static void plat_runtime_setup(void) { runtime_setup_calls++; }
static void tegra_fc_enable_fiq_to_ccplex_routing(void) { fiq_route_calls++; }
static void tegra_pmc_clear_reset_type(void) { clear_reset_calls++; }
#endif

int tegra_soc_pwr_domain_on(u_register_t mpidr);
int tegra_soc_pwr_domain_off(const psci_power_state_t *target_state);
int tegra_soc_pwr_domain_suspend(const psci_power_state_t *target_state);
int tegra_soc_pwr_domain_power_down_wfi(const psci_power_state_t *target_state);
int tegra_soc_pwr_domain_on_finish(const psci_power_state_t *target_state);
'''

harness += "\n#if SWITCH_LITE_SC7\n" + clocks_cclk + "\n" + helper + "\n" + lite_handler_helpers + "\n#endif\n"
harness += handlers + "\n" + pm_ops
harness += r'''
static void reset_counters(void) {
    init_calls = enable_reqs = cancel_reqs = do_idle_reqs = 0;
    pmc_writes = dfll_ctrl_reads = 0;
    wfi_calls = panic_calls = console_off_calls = 0;
    gic_init_calls = gic_pcpu_init_calls = gic_cpuif_deact_calls = 0;
    se_suspend_calls = se_save_tzram_calls = se_resume_calls = 0;
    bpmp_suspend_calls = bpmp_resume_calls = 0;
    fc_cpu_powerdn_calls = fc_soc_powerdn_calls = fc_cpu_off_calls = 0;
    fc_cluster_idle_calls = fc_lock_cluster_calls = 0;
    pmc_resume_calls = pmc_cpu_on_calls = fc_cpu_on_calls = 0;
    woken_mask = 0U;
    cancel_while_pgexit_locked = false;
#if SWITCH_LITE_SC7
    delays = 0;
    memset(pmc_write_counts, 0, sizeof(pmc_write_counts));
    clocks_save_calls = clocks_invalidate_calls = clocks_restore_calls = 0;
    pads_save_calls = pads_restore_calls = 0;
    secondary_setup_calls = runtime_setup_calls = fiq_route_calls = clear_reset_calls = 0;
#endif
}

static void setup_valid_board(void) {
    memset(&params, 0, sizeof(params));
    memset(pmc, 0, sizeof(pmc));
    memset(gicd, 0, sizeof(gicd));
    memset(gicd_banked, 0, sizeof(gicd_banked));
    memset(gicc_banked, 0, sizeof(gicc_banked));
    memset(car, 0, sizeof(car));
    memset(dfll, 0, sizeof(dfll));
    sysctr0 = mselect_cfg = misc_apb_sec = misc_dvfs_pwm = 0;
    res_sema = SIGN_OF_LIFE;
    init_status = reply_status = cancel_reply_status = se_suspend_status = 0;
    ccx_allowed = true;
    bpmp_timeout_unanswered = false;
    tegra_bpmp_available = true;
    pgexit_lock_depth = 0;
    current_cpu = 0;
    for (unsigned c = 0; c < PLATFORM_MAX_CPUS_PER_CLUSTER; c++) {
        cpu_hw_on[c] = true;
        cpu_powergate_mask[c] = 1;
    }
    pmc[0] = 0x00024101U;           /* INTR_POLARITY | SIDE_EFFECT_LP0 | PWRREQ_POL | KBC_CLK_OE */
    pmc[PMC_PWRGATE_STATUS / 4] = (1U << 14) | (1U << 9) | (1U << 10) | (1U << 11);
    pmc[0x0c / 4] = 0x13579U;
    pmc[0x10 / 4] = 0x24680U;
    pmc[0x14 / 4] = 0x5500U;
    pmc[0x18 / 4] = 0x11U;
    pmc[0x3c / 4] = 0x1234U;        /* Baseline COREPWRGOOD_TIMER */
    pmc[0xc8 / 4] = 0x9abcU;        /* Baseline CPUPWRGOOD_TIMER */
    pmc[0xcc / 4] = 0xdef0U;        /* Baseline CPUPWROFF_TIMER */
    pmc[0xe0 / 4] = 0x5678U;        /* Baseline COREPWROFF_TIMER */
    params.tzdram_base = 0xFFF00000U;
    params.tzdram_size = 0x100000U;
    /* Hekate B01 handoff: SCRATCH1 may be zero; both entries are in DRAM. */
    pmc[PMC_SECURE_SCRATCH119 / 4] = 0xFFE3EC00U;
    pmc[PMC_SCRATCH39 / 4] = 0xFFE00040U;
    pmc[0x160 / 4] = 0x12345U;
    pmc[0x164 / 4] = 0x87654U;
    pmc[0x168 / 4] = (1U << 19) | 0x80U;
    pmc[0x16c / 4] = 0x22U;

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
        gicc_banked[c][0x000 / 4] = 0x463U; /* EnableGrp0|Grp1|FIQEn|EOImodeNS (bit 10) */
        gicc_banked[c][0x004 / 4] = 0xf8U;
        gicc_banked[c][0x01c / 4] = 0x03U; /* GICC_ABPR at 0x01c */
    }

#if SWITCH_LITE_SC7
    car[0x020 / 4] = CCLK_POLICY_PLLX;
    car[0x0e0 / 4] = PLL_ON | 0x6802U;
    memset(&sc7_state, 0, sizeof(sc7_state));
    memset(&sc7_abort_state, 0, sizeof(sc7_abort_state));
    sc7_pgexit_locked = false;
    lite_bpmp_lock.lock = 0U;
    lite_bpmp_init_status = 0;
    lite_bpmp_init_done = false;
    fc_seq_intercept = 0U;
    inject_fc_wake_in_delay = false;
    memset(cpu_c7_suspended, 0, sizeof(cpu_c7_suspended));
    memset(&gic_dist, 0, sizeof(gic_dist));
    memset(gic_pcpu, 0, sizeof(gic_pcpu));
    isr_el1 = 0U;
    wake_write_fault = false;
    pmc_config_ro_mask = 0U;
    inject_wake_in_delay = false;
    sticky_wake_status = false;
    clocks_valid = false;
    pads_valid = false;
#endif
    reset_counters();
}

static void run_power_down_wfi(const psci_power_state_t *state) {
    wfi_jmp_active = true;
    int rc = setjmp(wfi_jmp);
    if (rc == 0) {
        tegra_pwr_domain_power_down_wfi(state);
    }
    wfi_jmp_active = false;
    assert(rc == 1);
}

static void run(unsigned int state, int expected) {
    psci_power_state_t out = { { 0, 0, 0 } }, before = out;
    int rc;
    reset_counters();
    if (psci_validate_psci_pstate(state) != PSCI_E_SUCCESS) {
        assert(expected == PSCI_E_INVALID_PARAMS);
        return;
    }
    rc = tegra_soc_validate_power_state(state, &out);
    assert(rc == expected);
    /* validate_power_state runs unlocked before coordination: zero BPMP/PMC writes. */
    assert(enable_reqs == 0 && cancel_reqs == 0 && pmc_writes == 0);
#if SWITCH_LITE_SC7
    assert(delays == 0);
    /* Real BL31 builds with ENABLE_ASSERTIONS=1: psci_cpu_suspend() asserts rc == INVALID_PARAMS. */
    if (b01 && rc != PSCI_E_SUCCESS) {
        assert(rc == PSCI_E_INVALID_PARAMS);
    }
    if (expected == 0 && b01 && psci_get_pstate_id(state) == (int)PSTATE_ID_SOC_POWERDN) {
        assert(out.pwr_domain_state[MPIDR_AFFLVL0] == PLAT_MAX_OFF_STATE);
        assert(out.pwr_domain_state[MPIDR_AFFLVL1] == PSTATE_ID_SOC_POWERDN);
        assert(out.pwr_domain_state[PLAT_MAX_PWR_LVL] == PLAT_SYS_SUSPEND_STATE_ID);
    }
#endif
    if (expected != 0) {
        assert(memcmp(&out, &before, sizeof(out)) == 0);
    }
}

#if SWITCH_LITE_SC7
static void verify_prepared_pmc_state(void) {
    assert(delays == 2U);
    assert(pmc[0x3c / 4] == 0x6c00U);
    assert(pmc[0xe0 / 4] == 0x5a8U);
    assert(pmc[0xc8 / 4] == 0U && pmc[0xcc / 4] == 0U);
    assert((pmc[0] & ((1U << 9) | (1U << 11) | (1U << 16) | (1U << 17))) ==
           ((1U << 9) | (1U << 11) | (1U << 16) | (1U << 17)));
    assert((pmc[0] & ((1U << 5) | (1U << 8) | (1U << 10) | (1U << 14) | (1U << 15))) == 0U);
    assert((pmc[0] & 1U) == 1U);
    assert(pmc[0x168 / 4] == 0x80U);
    assert(pmc[0x164 / 4] == (0x87654U & ~(1U << 19)));
    assert(pmc[0x160 / 4] == 0x92345U);
}

static void verify_restored_pmc_state(void) {
    assert(pmc[0x3c / 4] == 0x1234U);
    assert(pmc[0xe0 / 4] == 0x5678U);
    assert(pmc[0xc8 / 4] == 0x9abcU);
    assert(pmc[0xcc / 4] == 0xdef0U);
    assert(pmc[0] == 0x00024101U);
    assert(pmc[0x160 / 4] == 0x12345U);
    assert(pmc[0x164 / 4] == 0x87654U);
}

static void simulate_sc7_hw_wipe_and_tfa_gic_init(void) {
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
        gicc_banked[c][0x000 / 4] = 0x209U; /* EnableGrp1 and EOImodeNS wiped by TF-A! */
}

/* Models pinned lib/psci/psci_suspend.c call order for CPU_SUSPEND. */
static int run_psci_cpu_suspend(unsigned cpu, unsigned power_state,
                                psci_power_state_t *out_state,
                                bool inject_late_wake) {
    psci_power_state_t req = { { 0, 0, 0 } };
    plat_local_state_t states[PLATFORM_MAX_CPUS_PER_CLUSTER] = { 0, 0, 0, 0 };
    int err;

    current_cpu = cpu;
    err = tegra_soc_validate_power_state(power_state, &req);
    if (err != PSCI_E_SUCCESS)
        return err;

    if (read_isr_el1() != 0U)
        return PSCI_E_SUCCESS;

    if (req.pwr_domain_state[MPIDR_AFFLVL1] != PSCI_LOCAL_STATE_RUN) {
        states[cpu] = req.pwr_domain_state[MPIDR_AFFLVL1];
        plat_local_state_t t1 =
            tegra_soc_get_target_pwr_state(MPIDR_AFFLVL1, states,
                                           PLATFORM_MAX_CPUS_PER_CLUSTER);
        req.pwr_domain_state[MPIDR_AFFLVL1] = t1;
        if (t1 == PSCI_LOCAL_STATE_RUN) {
            req.pwr_domain_state[MPIDR_AFFLVL2] = PSCI_LOCAL_STATE_RUN;
        } else if (req.pwr_domain_state[MPIDR_AFFLVL2] != PSCI_LOCAL_STATE_RUN) {
            states[cpu] = req.pwr_domain_state[MPIDR_AFFLVL2];
            plat_local_state_t t2 =
                tegra_soc_get_target_pwr_state(MPIDR_AFFLVL2, states,
                                               PLATFORM_MAX_CPUS_PER_CLUSTER);
            req.pwr_domain_state[MPIDR_AFFLVL2] = t2;
        }
    }

    if (inject_late_wake)
        isr_el1 = (1U << 7);

    tegra_pwr_domain_suspend(&req);
    run_power_down_wfi(&req);
    if (out_state != NULL)
        *out_state = req;
    return PSCI_E_SUCCESS;
}
#endif

int main(void) {
    const unsigned c7 = (1U << PSTATE_TYPE_SHIFT) | PSTATE_ID_CORE_POWERDN;   /* 0x40000007 */
    const unsigned cc6 = (1U << PSTATE_TYPE_SHIFT) | PSTATE_ID_CLUSTER_IDLE;  /* 0x40000010 */
    const unsigned sc7 = (1U << PSTATE_TYPE_SHIFT) | PSTATE_ID_SOC_POWERDN;   /* 0x4000001B */

    /* Legacy state IDs with bits [29:28] or [25:24] set are rejected by extended PSCI! */
    assert(psci_validate_psci_pstate(0x01010010U) == PSCI_E_SUCCESS); /* bit 24 ok, bit 28 bad */
    assert(psci_validate_psci_pstate(0x10000007U) == PSCI_E_INVALID_PARAMS);

    b01 = true;
    setup_valid_board();
    run(c7, 0);
    run(cc6, 0);
    run(0x400000ffU, PSCI_E_INVALID_PARAMS);
    run(sc7, 0);

#if SWITCH_LITE_SC7
    /* Per-CPU lockless C7 state and SC7 control/abort state must not share cache lines. */
    assert(sizeof(gic_pcpu[0]) >= 64U && (sizeof(gic_pcpu[0]) % 64U) == 0U);
    assert(((uintptr_t)&gic_pcpu[1] - (uintptr_t)&gic_pcpu[0]) >= 64U);
    assert(sizeof(cpu_c7_suspended[0]) >= 64U && (sizeof(cpu_c7_suspended[0]) % 64U) == 0U);
    assert(((uintptr_t)&cpu_c7_suspended[1] - (uintptr_t)&cpu_c7_suspended[0]) >= 64U);
    assert(((uintptr_t)&sc7_pgexit_locked & 63U) == 0U);
    assert(sizeof(sc7_state) >= 64U && (sizeof(sc7_state) % 64U) == 0U);
    assert(sizeof(sc7_abort_state) >= 64U && (sizeof(sc7_abort_state) % 64U) == 0U);
    assert(((uintptr_t)&sc7_state & 63U) == 0U && ((uintptr_t)&sc7_abort_state & 63U) == 0U);
    assert(((uintptr_t)&sc7_state / 64U) != ((uintptr_t)&sc7_abort_state / 64U));

    /* Direct prepare/cancel: single-owner prepare arms BPMP and restores PMC on owner cancel. */
    setup_valid_board();
    assert(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS);
    assert(enable_reqs == 1 && cancel_reqs == 0 && tegra_lite_sc7_is_armed());
    verify_prepared_pmc_state();
    /* Non-owner CPU must not observe armed state or cancel CPU 0's transition. */
    current_cpu = 1;
    assert(!tegra_lite_sc7_is_armed());
    tegra_lite_sc7_cancel();
    assert(cancel_reqs == 0);
    verify_prepared_pmc_state();
    current_cpu = 0;
    assert(tegra_lite_sc7_is_armed());
    memset(pmc_write_counts, 0, sizeof(pmc_write_counts));
    tegra_lite_sc7_cancel();
    assert(cancel_reqs == 1 && !tegra_lite_sc7_is_armed());
    verify_restored_pmc_state();
    assert(pmc_write_counts[0x168 / 4] == 0U && pmc_write_counts[0x18 / 4] == 0U &&
           pmc_write_counts[0x16c / 4] == 0U);
    tegra_lite_sc7_cancel();
    assert(cancel_reqs == 1); /* idempotent once cancelled */

    /* Erista SCRATCH1 cannot substitute for Mariko SECURE_SCRATCH119. */
    setup_valid_board();
    pmc[PMC_SCRATCH1 / 4] = 0x80010000U;
    pmc[PMC_SECURE_SCRATCH119 / 4] = 0;
    assert(tegra_lite_sc7_preflight() == PSCI_E_NOT_SUPPORTED);
    run(sc7, PSCI_E_INVALID_PARAMS);
    const uint32_t invalid_entries[] = {0U, 0x4003e000U, 0x7ffffffcU,
                                       0xFFF00000U, 0xFFFFFFFCU, 0xFFE00041U};
    for (unsigned i = 0; i < sizeof(invalid_entries) / sizeof(invalid_entries[0]); i++) {
        setup_valid_board();
        pmc[PMC_SECURE_SCRATCH119 / 4] = invalid_entries[i];
        assert(tegra_lite_sc7_preflight() == PSCI_E_NOT_SUPPORTED);
        run(sc7, PSCI_E_INVALID_PARAMS);
        setup_valid_board();
        pmc[PMC_SCRATCH39 / 4] = invalid_entries[i];
        assert(tegra_lite_sc7_preflight() == PSCI_E_NOT_SUPPORTED);
        run(sc7, PSCI_E_INVALID_PARAMS);
    }

    /* Unarmed GIC INTID 118 (disabled or Group 0) must reject SC7 cleanly. */
    setup_valid_board();
    gicd[0x100 / 4 + 3] &= ~(1U << 22);
    assert(tegra_lite_sc7_preflight() == PSCI_E_DENIED);
    run(sc7, PSCI_E_INVALID_PARAMS);
    setup_valid_board();
    gicd[0x080 / 4 + 3] &= ~(1U << 22);
    assert(tegra_lite_sc7_preflight() == PSCI_E_DENIED);
    run(sc7, PSCI_E_INVALID_PARAMS);

    /* F4: CCLK/DFLL preflight rejects DFLL/unknown policies and allows open-loop variants. */
    const uint32_t bad_cclk[] = {0x20009999U, 0x20008898U, 0x2000ffffU, 0x20018888U};
    for (unsigned i = 0; i < sizeof(bad_cclk) / sizeof(bad_cclk[0]); i++) {
        setup_valid_board();
        car[0x020 / 4] = bad_cclk[i];
        assert(tegra_lite_sc7_preflight() == PSCI_E_DENIED);
        run(sc7, PSCI_E_INVALID_PARAMS);
    }
    setup_valid_board();
    car[0x0e0 / 4] &= ~PLL_ON;
    assert(tegra_lite_sc7_preflight() == PSCI_E_DENIED);
    run(sc7, PSCI_E_INVALID_PARAMS);
    setup_valid_board();
    car[0x020 / 4] = 0x20008880U;
    assert(tegra_lite_sc7_preflight() == PSCI_E_SUCCESS);
    run(sc7, PSCI_E_SUCCESS);
    setup_valid_board();
    car[0x020 / 4] = 0x30008888U;
    assert(tegra_lite_sc7_preflight() == PSCI_E_SUCCESS);
    run(sc7, PSCI_E_SUCCESS);
    /* Closed-loop DFLL is only read when DVFS clock is enabled and out of reset. */
    setup_valid_board();
    dfll[DVFS_DFLL_CTRL / 4] = ENABLE_CLOSED_LOOP;
    run(sc7, PSCI_E_SUCCESS);
    assert(dfll_ctrl_reads == 0U);
    setup_valid_board();
    car[CAR_CLK_OUT_ENB_W / 4] = CAR_DVFS_BIT;
    car[CAR_RST_DEV_W / 4] = 0U;
    dfll[DVFS_DFLL_CTRL / 4] = ENABLE_CLOSED_LOOP;
    run(sc7, PSCI_E_INVALID_PARAMS);
    assert(dfll_ctrl_reads > 0U);

    /* Sticky BPMP init failure: upstream bpmp.c returns 0 on 2nd call when BPMP_NOT_PRESENT. */
    setup_valid_board();
    init_status = -1;
    run(sc7, PSCI_E_INVALID_PARAMS);
    init_status = 0; /* Simulate upstream bpmp.c 2nd-call quirk after BPMP_NOT_PRESENT */
    run(sc7, PSCI_E_INVALID_PARAMS);
    assert(init_calls == 0);

    /* Test GICv2 per-CPU + distributor save, armed-state persistence across GIC save, wipe, restore. */
    setup_valid_board();
    assert(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS);
    for (unsigned c = 0; c < 4; c++) {
        current_cpu = c;
        tegra_lite_gic_pcpu_save(c);
    }
    tegra_lite_gic_pcpu_invalidate(3);
    current_cpu = 0;
    tegra_lite_gic_dist_save();
    assert(tegra_lite_sc7_is_armed()); /* Must persist through GIC save until commit/cancel! */

    simulate_sc7_hw_wipe_and_tfa_gic_init();
    current_cpu = 0;
    tegra_lite_gic_dist_restore();
    assert(!tegra_lite_sc7_is_armed());
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
        assert((gicc_banked[c][0x000 / 4] & 0x402U) == 0x402U); /* EnableGrp1 | EOImodeNS (bit 10) */
        assert(gicc_banked[c][0x004 / 4] == 0xf8U);
        assert(gicc_banked[c][0x01c / 4] == 0x03U); /* GICC_ABPR restored! */
        assert((gicd_banked[c][0x100 / 4] & 0xffff00ffU) == 0x400000ffU);
        assert((gicd_banked[c][0x100 / 4] & 0x0000ff00U) == 0U); /* Secure SGIs untouched! */
    }
    current_cpu = 3;
    tegra_lite_gic_pcpu_restore(3);
    assert((gicc_banked[3][0x000 / 4] & 0x402U) == 0U);

    /* Valid 4-core Mariko SC7 cycle: CPU 3 OFF, CPUs 1-2 C7, CPU 0 commits SC7 & wakes 1-2. */
    setup_valid_board();
    psci_power_state_t off_state = { { PLAT_MAX_OFF_STATE, PLAT_MAX_OFF_STATE, PLAT_MAX_OFF_STATE } };
    current_cpu = 3;
    tegra_pwr_domain_off(&off_state);
    psci_power_state_t s1 = { { 0 } }, s2 = { { 0 } }, s0 = { { 0 } };
    assert(run_psci_cpu_suspend(1, sc7, &s1, false) == PSCI_E_SUCCESS);
    assert(run_psci_cpu_suspend(2, sc7, &s2, false) == PSCI_E_SUCCESS);
    assert(s1.pwr_domain_state[MPIDR_AFFLVL1] == PSCI_LOCAL_STATE_RUN);
    assert(s2.pwr_domain_state[MPIDR_AFFLVL2] == PSCI_LOCAL_STATE_RUN);
    assert(enable_reqs == 0 && cancel_reqs == 0 && pmc_writes == 0 && pgexit_lock_depth == 0);
    assert(cpu_c7_suspended[1].suspended == 1U && cpu_c7_suspended[2].suspended == 1U && cpu_c7_suspended[3].suspended == 0U);

    assert(run_psci_cpu_suspend(0, sc7, &s0, false) == PSCI_E_SUCCESS);
    assert(s0.pwr_domain_state[PLAT_MAX_PWR_LVL] == PLAT_SYS_SUSPEND_STATE_ID);
    assert(enable_reqs == 1 && cancel_reqs == 0 && !tegra_lite_sc7_is_armed() && !tegra_lite_sc7_is_aborted());
    verify_prepared_pmc_state();
    assert(se_suspend_calls == 1 && clocks_save_calls == 1 && pads_save_calls == 1);
    assert(se_save_tzram_calls == 1 && bpmp_suspend_calls == 1 && fc_soc_powerdn_calls == 1);
    assert(console_off_calls == 1 && wfi_calls == 3 && panic_calls == 0);
    assert(cpu_c7_suspended[0].suspended == 0U);

    simulate_sc7_hw_wipe_and_tfa_gic_init();
    reset_counters();
    current_cpu = 0;
    cpu_hw_on[0] = true;
    tegra_pwr_domain_on_finish(&s0);
    assert(gic_init_calls == 1 && se_resume_calls == 1 && clocks_restore_calls == 1 && pads_restore_calls == 1);
    assert(bpmp_resume_calls == 1 && pmc_resume_calls == 0 && panic_calls == 0);
    assert(woken_mask == 0x6U && pmc_cpu_on_calls == 2 && fc_cpu_on_calls == 0);
    assert((gicc_banked[0][0x000 / 4] & 0x402U) == 0x402U && gicc_banked[0][0x01c / 4] == 0x03U);

    /* F1: Non-primary final entry (CPU 0 suspends first, CPU 3 last) must degrade to C7! */
    setup_valid_board();
    psci_power_state_t st = { { 0 } };
    for (unsigned c = 0; c < 4; c++) {
        assert(run_psci_cpu_suspend(c, sc7, &st, false) == PSCI_E_SUCCESS);
        assert(st.pwr_domain_state[MPIDR_AFFLVL1] == PSCI_LOCAL_STATE_RUN);
        assert(st.pwr_domain_state[PLAT_MAX_PWR_LVL] == PSCI_LOCAL_STATE_RUN);
    }
    assert(enable_reqs == 0 && cancel_reqs == 0 && pmc_writes == 0);
    assert(fc_soc_powerdn_calls == 0 && fc_cpu_powerdn_calls == 4 && pgexit_lock_depth == 0);
    assert(cpu_c7_suspended[3].suspended == 1U && !tegra_lite_sc7_is_armed());

    /* Non-primary SYSTEM_SUSPEND downgrades at afflvl 1 and handles PSTATE_ID_SOC_POWERDN at afflvl 0. */
    setup_valid_board();
    cpu_hw_on[0] = cpu_hw_on[2] = cpu_hw_on[3] = false;
    current_cpu = 1;
    plat_local_state_t sys_states[4] = { 0, PSTATE_ID_SOC_POWERDN, 0, 0 };
    assert(tegra_soc_get_target_pwr_state(MPIDR_AFFLVL1, sys_states, 4) == PSCI_LOCAL_STATE_RUN);
    psci_power_state_t deg_sys = { { PSTATE_ID_SOC_POWERDN, PSCI_LOCAL_STATE_RUN, PSCI_LOCAL_STATE_RUN } };
    assert(tegra_soc_pwr_domain_suspend(&deg_sys) == PSCI_E_SUCCESS);
    assert(fc_cpu_powerdn_calls == 1 && enable_reqs == 0 && !tegra_lite_sc7_is_armed());

    /* F2: Non-last CPU 0 downgrade leaves BPMP unarmed; subsequent CC6 and CPU_OFF stay clean. */
    setup_valid_board();
    assert(run_psci_cpu_suspend(0, sc7, &s0, false) == PSCI_E_SUCCESS);
    assert(s0.pwr_domain_state[PLAT_MAX_PWR_LVL] == PSCI_LOCAL_STATE_RUN);
    assert(enable_reqs == 0 && cancel_reqs == 0 && pmc_writes == 0 && pgexit_lock_depth == 0);
    assert(!tegra_lite_sc7_is_armed());
    plat_local_state_t cc6_states[4] = { 0, PSTATE_ID_CLUSTER_IDLE, 0, 0 };
    current_cpu = 1;
    assert(tegra_soc_get_target_pwr_state(MPIDR_AFFLVL1, cc6_states, 4) == PSTATE_ID_CLUSTER_IDLE);
    assert(do_idle_reqs == 1 && enable_reqs == 0 && !tegra_lite_sc7_is_armed());
    /* PSCI CPU_OFF on last CPU 0 uses PLAT_MAX_OFF_STATE and must never arm SC7. */
    setup_valid_board();
    cpu_hw_on[1] = cpu_hw_on[2] = cpu_hw_on[3] = false;
    current_cpu = 0;
    plat_local_state_t off_req[4] = { PLAT_MAX_OFF_STATE, 0, 0, 0 };
    (void)tegra_soc_get_target_pwr_state(MPIDR_AFFLVL1, off_req, 4);
    assert(enable_reqs == 0 && pmc_writes == 0 && pgexit_lock_depth == 0 && !tegra_lite_sc7_is_armed());

    /* Prepare failures during single-owner coordination degrade cleanly to C7 without leaks. */
    /* Timeout leaving unanswered mailbox fails closed until verified BPMP reset, preserving C7. */
    setup_valid_board();
    cpu_hw_on[1] = cpu_hw_on[2] = cpu_hw_on[3] = false;
    reply_status = -110;
    bpmp_timeout_unanswered = true;
    assert(run_psci_cpu_suspend(0, sc7, &s0, false) == PSCI_E_SUCCESS);
    assert(s0.pwr_domain_state[PLAT_MAX_PWR_LVL] == PSCI_LOCAL_STATE_RUN);
    assert(enable_reqs == 1 && cancel_reqs == 0 && pmc_writes == 0 &&
           pgexit_lock_depth == 0 && !tegra_lite_sc7_is_armed());
    assert((res_sema & CH_MASK(0U)) == 0U);
    verify_restored_pmc_state();
    assert(tegra_lite_sc7_preflight() == PSCI_E_DENIED);
    run(sc7, PSCI_E_INVALID_PARAMS);
    cpu_hw_on[0] = true;
    assert(run_psci_cpu_suspend(0, c7, &s0, false) == PSCI_E_SUCCESS);
    /* Verified BPMP reset restores SIGN_OF_LIFE; next SC7 disarms uncertain state then commits. */
    res_sema = SIGN_OF_LIFE;
    reply_status = 0;
    bpmp_timeout_unanswered = false;
    cpu_hw_on[0] = true;
    reset_counters();
    assert(run_psci_cpu_suspend(0, sc7, &s0, false) == PSCI_E_SUCCESS);
    assert(s0.pwr_domain_state[PLAT_MAX_PWR_LVL] == PLAT_SYS_SUSPEND_STATE_ID);
    assert(cancel_reqs == 1 && enable_reqs == 1 && fc_soc_powerdn_calls == 1 && panic_calls == 0);
    verify_prepared_pmc_state();

    /* Non-timeout BPMP error reply with free channel reconciles uncertain BPMP ownership cleanly. */
    setup_valid_board();
    cpu_hw_on[1] = cpu_hw_on[2] = cpu_hw_on[3] = false;
    reply_status = -5;
    assert(run_psci_cpu_suspend(0, sc7, &s0, false) == PSCI_E_SUCCESS);
    assert(s0.pwr_domain_state[PLAT_MAX_PWR_LVL] == PSCI_LOCAL_STATE_RUN);
    assert(enable_reqs == 1 && cancel_reqs == 1 && cancel_while_pgexit_locked &&
           pmc_writes == 0 && pgexit_lock_depth == 0 && !tegra_lite_sc7_is_armed());
    verify_restored_pmc_state();

    setup_valid_board();
    cpu_hw_on[1] = cpu_hw_on[2] = cpu_hw_on[3] = false;
    wake_write_fault = true;
    assert(run_psci_cpu_suspend(0, sc7, &s0, false) == PSCI_E_SUCCESS);
    assert(s0.pwr_domain_state[PLAT_MAX_PWR_LVL] == PSCI_LOCAL_STATE_RUN);
    assert(enable_reqs == 1 && cancel_reqs == 1 && pgexit_lock_depth == 0 && !tegra_lite_sc7_is_armed());
    verify_restored_pmc_state();

    setup_valid_board();
    cpu_hw_on[1] = cpu_hw_on[2] = cpu_hw_on[3] = false;
    pmc_config_ro_mask = (1U << 9); /* Reject PWRREQ_OE readback while allowing other bits to write */
    assert(run_psci_cpu_suspend(0, sc7, &s0, false) == PSCI_E_SUCCESS);
    assert(s0.pwr_domain_state[PLAT_MAX_PWR_LVL] == PSCI_LOCAL_STATE_RUN);
    assert(enable_reqs == 1 && cancel_reqs == 1 && pgexit_lock_depth == 0 && !tegra_lite_sc7_is_armed());
    verify_restored_pmc_state();
    assert(pmc_write_counts[0x160 / 4] == 0U && pmc_write_counts[0x164 / 4] == 0U &&
           pmc_write_counts[0x168 / 4] == 0U && pmc_write_counts[0x18 / 4] == 0U &&
           pmc_write_counts[0x16c / 4] == 0U);

    /* F3 + Abort path: failed tegra_se_suspend() after tegra_lite_gic_dist_save() rolls back cleanly. */
    setup_valid_board();
    assert(run_psci_cpu_suspend(1, sc7, NULL, false) == PSCI_E_SUCCESS);
    assert(run_psci_cpu_suspend(2, sc7, NULL, false) == PSCI_E_SUCCESS);
    assert(run_psci_cpu_suspend(3, sc7, NULL, false) == PSCI_E_SUCCESS);
    reset_counters();
    se_suspend_status = -1;
    assert(run_psci_cpu_suspend(0, sc7, &s0, false) == PSCI_E_SUCCESS);
    assert(s0.pwr_domain_state[PLAT_MAX_PWR_LVL] == PLAT_SYS_SUSPEND_STATE_ID);
    assert(enable_reqs == 1 && cancel_reqs == 1 && cancel_while_pgexit_locked);
    assert(!tegra_lite_sc7_is_armed() && tegra_lite_sc7_is_aborted());
    verify_restored_pmc_state();
    assert(pmc_write_counts[0x168 / 4] == 1U && pmc_write_counts[0x18 / 4] == 1U &&
           pmc_write_counts[0x16c / 4] == 1U);
    assert(pgexit_lock_depth == 0 && !gic_dist.valid && !clocks_valid && pads_save_calls == 0);
    assert(clocks_save_calls == 1 && clocks_invalidate_calls == 1);
    assert(cpu_c7_suspended[0].suspended == 1U && fc_cpu_powerdn_calls == 1);
    assert(se_save_tzram_calls == 0 && bpmp_suspend_calls == 0 && fc_soc_powerdn_calls == 0);
    assert(console_off_calls == 0 && wfi_calls == 1 && panic_calls == 0);

    /* CPU 0 wakes from aborted-SC7 C7: downgrades to C7 restore, no panic, no GICD wipe. */
    reset_counters();
    gicc_banked[0][0x000 / 4] = 0x209U;
    gicc_banked[0][0x01c / 4] = 0U;
    current_cpu = 0;
    cpu_hw_on[0] = true;
    tegra_pwr_domain_on_finish(&s0);
    assert(!tegra_lite_sc7_is_aborted());
    assert(gic_init_calls == 0 && gic_pcpu_init_calls == 1);
    assert(se_resume_calls == 0 && clocks_restore_calls == 0 && pads_restore_calls == 0);
    assert(bpmp_resume_calls == 0 && woken_mask == 0U && panic_calls == 0);
    assert(cpu_c7_suspended[0].suspended == 0U);
    assert((gicc_banked[0][0x000 / 4] & 0x402U) == 0x402U && gicc_banked[0][0x01c / 4] == 0x03U);

    /* Follow-up valid SC7 after aborted SC7 succeeds cleanly. */
    se_suspend_status = 0;
    reset_counters();
    assert(run_psci_cpu_suspend(0, sc7, &s0, false) == PSCI_E_SUCCESS);
    assert(enable_reqs == 1 && cancel_reqs == 0 && fc_soc_powerdn_calls == 1 && panic_calls == 0);
    verify_prepared_pmc_state();

    /* Abort with unanswered BPMP cancel timeout restores PMC immediately and fails closed until reset. */
    setup_valid_board();
    cpu_hw_on[1] = cpu_hw_on[2] = cpu_hw_on[3] = false;
    se_suspend_status = -1;
    cancel_reply_status = -110;
    bpmp_timeout_unanswered = true;
    assert(run_psci_cpu_suspend(0, sc7, &s0, false) == PSCI_E_SUCCESS);
    assert(enable_reqs == 1 && cancel_reqs == 1 && cancel_while_pgexit_locked);
    assert(!tegra_lite_sc7_is_armed() && tegra_lite_sc7_is_aborted() && pgexit_lock_depth == 0);
    assert((res_sema & CH_MASK(0U)) == 0U);
    verify_restored_pmc_state();
    assert(se_save_tzram_calls == 0 && bpmp_suspend_calls == 0 && fc_soc_powerdn_calls == 0);
    assert(console_off_calls == 0 && wfi_calls == 1 && panic_calls == 0);
    reset_counters();
    current_cpu = 0;
    cpu_hw_on[0] = true;
    tegra_pwr_domain_on_finish(&s0);
    assert(!tegra_lite_sc7_is_aborted() && gic_init_calls == 0 && gic_pcpu_init_calls == 1 && panic_calls == 0);
    assert(tegra_lite_sc7_preflight() == PSCI_E_DENIED);
    run(sc7, PSCI_E_INVALID_PARAMS);
    res_sema = SIGN_OF_LIFE;
    se_suspend_status = 0;
    cancel_reply_status = 0;
    bpmp_timeout_unanswered = false;
    reset_counters();
    assert(run_psci_cpu_suspend(0, sc7, &s0, false) == PSCI_E_SUCCESS);
    assert(cancel_reqs == 1 && enable_reqs == 1 && fc_soc_powerdn_calls == 1 && panic_calls == 0);
    verify_prepared_pmc_state();

    /* Early secondary wakeup race: CPU 1 observes abort (downgrades to C7) without clearing owner CPU 0's abort state. */
    setup_valid_board();
    assert(run_psci_cpu_suspend(1, sc7, NULL, false) == PSCI_E_SUCCESS);
    assert(run_psci_cpu_suspend(2, sc7, NULL, false) == PSCI_E_SUCCESS);
    assert(run_psci_cpu_suspend(3, sc7, NULL, false) == PSCI_E_SUCCESS);
    reset_counters();
    se_suspend_status = -1;
    current_cpu = 0;
    psci_power_state_t race_st = { { 0 } };
    assert(tegra_soc_validate_power_state(sc7, &race_st) == PSCI_E_SUCCESS);
    plat_local_state_t race_lvl1[4] = { race_st.pwr_domain_state[MPIDR_AFFLVL1], 0, 0, 0 };
    assert(tegra_soc_get_target_pwr_state(MPIDR_AFFLVL1, race_lvl1, 4) == PSTATE_ID_SOC_POWERDN);
    plat_local_state_t race_lvl2[4] = { race_st.pwr_domain_state[MPIDR_AFFLVL2], 0, 0, 0 };
    assert(tegra_soc_get_target_pwr_state(MPIDR_AFFLVL2, race_lvl2, 4) == PSTATE_ID_SOC_POWERDN);
    tegra_pwr_domain_suspend(&race_st);
    assert(!tegra_lite_sc7_is_armed() && tegra_lite_sc7_is_aborted() && cancel_reqs == 1);
    verify_restored_pmc_state();
    /* CPU 1 wakes early with stale SOC_POWERDN state: downgrades to C7 and preserves owner CPU 0's abort state. */
    gicc_banked[1][0x000 / 4] = 0x209U;
    gicc_banked[1][0x01c / 4] = 0U;
    current_cpu = 1;
    cpu_hw_on[1] = true;
    tegra_pwr_domain_on_finish(&race_st);
    assert(tegra_lite_sc7_is_aborted() && gic_init_calls == 0 && gic_pcpu_init_calls == 1 &&
           se_resume_calls == 0 && clocks_restore_calls == 0 && pads_restore_calls == 0 && panic_calls == 0);
    assert((gicc_banked[1][0x000 / 4] & 0x402U) == 0x402U && gicc_banked[1][0x01c / 4] == 0x03U);
    /* CPU 0 must STILL skip SC7 commit/console-off because sc7_state is not armed. */
    current_cpu = 0;
    run_power_down_wfi(&race_st);
    assert(se_save_tzram_calls == 0 && bpmp_suspend_calls == 0 && fc_soc_powerdn_calls == 0);
    assert(console_off_calls == 0 && wfi_calls == 1 && panic_calls == 0);
    /* Owner CPU 0 wakes up: also downgrades to C7, restores GICC, and clears abort state. */
    gicc_banked[0][0x000 / 4] = 0x209U;
    gicc_banked[0][0x01c / 4] = 0U;
    cpu_hw_on[0] = true;
    tegra_pwr_domain_on_finish(&race_st);
    assert(!tegra_lite_sc7_is_aborted() && gic_init_calls == 0 && gic_pcpu_init_calls == 2 &&
           se_resume_calls == 0 && clocks_restore_calls == 0 && pads_restore_calls == 0 && panic_calls == 0);
    assert((gicc_banked[0][0x000 / 4] & 0x402U) == 0x402U && gicc_banked[0][0x01c / 4] == 0x03U);

    /* Pending wake protection: pre-prepare, mid-prepare (latch), sticky WAKE2, and late L2-flush wake. */
    setup_valid_board();
    cpu_hw_on[1] = cpu_hw_on[2] = cpu_hw_on[3] = false;
    gicd[0x200 / 4 + 3] = (1U << 22); /* INTID 118 pending in GICD */
    assert(run_psci_cpu_suspend(0, sc7, &s0, false) == PSCI_E_SUCCESS);
    assert(s0.pwr_domain_state[PLAT_MAX_PWR_LVL] == PSCI_LOCAL_STATE_RUN);
    assert(enable_reqs == 0 && pmc_writes == 0 && pgexit_lock_depth == 0);
    verify_restored_pmc_state();

    setup_valid_board();
    cpu_hw_on[1] = cpu_hw_on[2] = cpu_hw_on[3] = false;
    inject_wake_in_delay = true;
    assert(run_psci_cpu_suspend(0, sc7, &s0, false) == PSCI_E_SUCCESS);
    assert(s0.pwr_domain_state[PLAT_MAX_PWR_LVL] == PSCI_LOCAL_STATE_RUN);
    assert(enable_reqs == 1 && cancel_reqs == 1 && pgexit_lock_depth == 0 && !tegra_lite_sc7_is_armed());
    verify_restored_pmc_state();

    setup_valid_board();
    cpu_hw_on[1] = cpu_hw_on[2] = cpu_hw_on[3] = false;
    sticky_wake_status = true;
    assert(run_psci_cpu_suspend(0, sc7, &s0, false) == PSCI_E_SUCCESS);
    assert(s0.pwr_domain_state[PLAT_MAX_PWR_LVL] == PSCI_LOCAL_STATE_RUN);
    assert(enable_reqs == 1 && cancel_reqs == 1 && pgexit_lock_depth == 0 && !tegra_lite_sc7_is_armed());
    verify_restored_pmc_state();
    assert(pmc[0x168 / 4] == ((1U << 19) | 0x80U) && pmc_write_counts[0x168 / 4] == 1U);

    setup_valid_board();
    cpu_hw_on[1] = cpu_hw_on[2] = cpu_hw_on[3] = false;
    assert(run_psci_cpu_suspend(0, sc7, &s0, true) == PSCI_E_SUCCESS);
    assert(enable_reqs == 1 && cancel_reqs == 1 && !tegra_lite_sc7_is_armed() && tegra_lite_sc7_is_aborted());
    verify_restored_pmc_state();
    assert(clocks_save_calls == 0 && se_suspend_calls == 0 && pads_save_calls == 0);
    assert(se_save_tzram_calls == 0 && fc_soc_powerdn_calls == 0 && console_off_calls == 0);
    reset_counters();
    current_cpu = 0;
    cpu_hw_on[0] = true;
    tegra_pwr_domain_on_finish(&s0);
    assert(!tegra_lite_sc7_is_aborted() && gic_init_calls == 0 && gic_pcpu_init_calls == 1 && panic_calls == 0);

    /* Concurrent abort race: CPU 1 wakes from C7 (end_pwrlvl=0) and calls CPU_SUSPEND(SC7),
     * resetting PSCI non-CPU nodes to RUN while CPU 0 is still in aborted-SC7 C7; CPU 1 RUN
     * wakeup must not clear CPU 0's abort state, and CPU 0 RUN wakeup must clear stale abort state. */
    setup_valid_board();
    cpu_hw_on[1] = cpu_hw_on[2] = cpu_hw_on[3] = false;
    se_suspend_status = -1;
    assert(run_psci_cpu_suspend(0, sc7, &s0, false) == PSCI_E_SUCCESS);
    assert(tegra_lite_sc7_is_aborted() && !tegra_lite_sc7_is_armed());
    reset_counters();
    psci_power_state_t overwritten_run = { { PLAT_MAX_OFF_STATE, PSCI_LOCAL_STATE_RUN, PSCI_LOCAL_STATE_RUN } };
    current_cpu = 1;
    cpu_hw_on[1] = true;
    tegra_pwr_domain_on_finish(&overwritten_run);
    assert(tegra_lite_sc7_is_aborted() && gic_init_calls == 0 && gic_pcpu_init_calls == 1 && panic_calls == 0);
    current_cpu = 0;
    cpu_hw_on[0] = true;
    tegra_pwr_domain_on_finish(&overwritten_run);
    assert(!tegra_lite_sc7_is_aborted() && gic_init_calls == 0 && gic_pcpu_init_calls == 2 && panic_calls == 0);

    /* Flow Controller intercepted secondary-core wake during prepare() and during L2 flush. */
    setup_valid_board();
    cpu_hw_on[1] = cpu_hw_on[2] = cpu_hw_on[3] = false;
    inject_fc_wake_in_delay = true;
    assert(run_psci_cpu_suspend(0, sc7, &s0, false) == PSCI_E_SUCCESS);
    assert(s0.pwr_domain_state[PLAT_MAX_PWR_LVL] == PSCI_LOCAL_STATE_RUN);
    assert(enable_reqs == 1 && cancel_reqs == 1 && pgexit_lock_depth == 0 && !tegra_lite_sc7_is_armed());
    verify_restored_pmc_state();

    setup_valid_board();
    cpu_hw_on[1] = cpu_hw_on[2] = cpu_hw_on[3] = false;
    current_cpu = 0;
    assert(tegra_soc_validate_power_state(sc7, &race_st) == PSCI_E_SUCCESS);
    plat_local_state_t fc_l1[4] = { race_st.pwr_domain_state[MPIDR_AFFLVL1], 0, 0, 0 };
    assert(tegra_soc_get_target_pwr_state(MPIDR_AFFLVL1, fc_l1, 4) == PSTATE_ID_SOC_POWERDN);
    plat_local_state_t fc_l2[4] = { race_st.pwr_domain_state[MPIDR_AFFLVL2], 0, 0, 0 };
    assert(tegra_soc_get_target_pwr_state(MPIDR_AFFLVL2, fc_l2, 4) == PSTATE_ID_SOC_POWERDN);
    fc_seq_intercept = (1U << 4); /* Secondary core wake arrived during L2 flush */
    tegra_pwr_domain_suspend(&race_st);
    run_power_down_wfi(&race_st);
    assert(enable_reqs == 1 && cancel_reqs == 1 && !tegra_lite_sc7_is_armed() && tegra_lite_sc7_is_aborted());
    verify_restored_pmc_state();
    assert(pgexit_lock_depth == 0 && clocks_save_calls == 0 && se_suspend_calls == 0 && fc_soc_powerdn_calls == 0);

    /* TOCTOU DFLL switch after validate_power_state still fails closed before BPMP arming. */
    setup_valid_board();
    cpu_hw_on[1] = cpu_hw_on[2] = cpu_hw_on[3] = false;
    current_cpu = 0;
    assert(tegra_soc_validate_power_state(sc7, &s0) == PSCI_E_SUCCESS);
    car[0x020 / 4] = 0x20009999U;
    plat_local_state_t toctou_states[4] = { s0.pwr_domain_state[MPIDR_AFFLVL1], 0, 0, 0 };
    assert(tegra_soc_get_target_pwr_state(MPIDR_AFFLVL1, toctou_states, 4) == PSCI_LOCAL_STATE_RUN);
    assert(enable_reqs == 0 && pmc_writes == 0 && pgexit_lock_depth == 0 && !tegra_lite_sc7_is_armed());
#endif

    setup_valid_board();
    init_status = -1;
    run(sc7, SWITCH_LITE_SC7 ? PSCI_E_INVALID_PARAMS : PSCI_E_NOT_SUPPORTED);
    params.sc7entry_fw_base = 0x80000000U;
    run(sc7, SWITCH_LITE_SC7 ? PSCI_E_INVALID_PARAMS : 0);

    b01 = false;
    setup_valid_board();
    init_status = -1;
    params.sc7entry_fw_base = 0x80000000U;
    run(sc7, 0);
    params.sc7entry_fw_base = 0;
    run(sc7, PSCI_E_NOT_SUPPORTED);
    init_status = 0;
    run(sc7, 0);

    /* Preserve baseline non-B01 / default PSCI paths (CPU_OFF, CC6, C7 suspend/resume). */
    setup_valid_board();
    psci_power_state_t nonb01_off = { { PLAT_MAX_OFF_STATE, PLAT_MAX_OFF_STATE, PLAT_MAX_OFF_STATE } };
    current_cpu = 3;
    tegra_pwr_domain_off(&nonb01_off);
    assert(fc_cpu_off_calls == 1 && gic_cpuif_deact_calls == 1);
    current_cpu = 0;
    plat_local_state_t nonb01_cc6[4] = { PSTATE_ID_CLUSTER_IDLE, 0, 0, 0 };
    assert(tegra_soc_get_target_pwr_state(MPIDR_AFFLVL1, nonb01_cc6, 4) == PSTATE_ID_CLUSTER_IDLE);
    assert(do_idle_reqs == 1);
    psci_power_state_t nonb01_c7 = { { PSTATE_ID_CORE_POWERDN, PSCI_LOCAL_STATE_RUN, PSCI_LOCAL_STATE_RUN } };
    tegra_pwr_domain_suspend(&nonb01_c7);
    run_power_down_wfi(&nonb01_c7);
    cpu_hw_on[0] = true;
    tegra_pwr_domain_on_finish(&nonb01_c7);
    assert(fc_cpu_powerdn_calls == 1 && pmc_resume_calls == 1 && gic_pcpu_init_calls == 1 && panic_calls == 0);

    puts("PASS: extended PSCI IDs, read-only SC7 preflight, single-owner coordination, non-primary/wake/DFLL guards, SE rollback/abort, and GICv2 restore");
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
