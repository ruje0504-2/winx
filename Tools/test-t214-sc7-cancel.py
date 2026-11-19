#!/usr/bin/env python3
"""Regression & fault-injection suite for T214 SC7 cancel/ownership/rollback.

Compiles the real pinned atf/plat/nvidia/tegra/soc/t210/t214/sc7.c against
actual pinned Tegra headers (bpmp.h, pmc.h, tegra_def.h) and an instrumented
host harness modeling pinned bpmp.c semaphore/mailbox semantics, PMC/wake
registers (including W1C WAKE2_STATUS), GIC, and multi-core PSCI call sites.

Usage:
    python3 winx/Tools/test-t214-sc7-cancel.py [path/to/atf]
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


MOCK_HEADERS = {
    "lib/utils_def.h": """\
#ifndef UTILS_DEF_H
#define UTILS_DEF_H

#define U(_x) (_x##U)
#define UL(_x) (_x##UL)
#define ULL(_x) (_x##ULL)
#ifndef __dead2
#define __dead2 __attribute__((noreturn))
#endif
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))

#endif
""",
    "lib/mmio.h": """\
#ifndef MMIO_H
#define MMIO_H

#include <stdint.h>

uint32_t harness_mmio_read_32(uintptr_t addr);
void harness_mmio_write_32(uintptr_t addr, uint32_t value);

static inline uint32_t mmio_read_32(uintptr_t addr)
{
\treturn harness_mmio_read_32(addr);
}

static inline void mmio_write_32(uintptr_t addr, uint32_t value)
{
\tharness_mmio_write_32(addr, value);
}

#endif
""",
    "lib/psci/psci.h": """\
#ifndef PSCI_H
#define PSCI_H

#include <stdint.h>

#define PSCI_E_SUCCESS          0
#define PSCI_E_NOT_SUPPORTED    -1
#define PSCI_E_INVALID_PARAMS   -2
#define PSCI_E_DENIED           -3
#define PSCI_E_ALREADY_ON       -4
#define PSCI_E_ON_PENDING       -5
#define PSCI_E_INTERN_FAIL      -6

#endif
""",
    "arch_helpers.h": """\
#ifndef ARCH_HELPERS_H
#define ARCH_HELPERS_H

#include <stddef.h>
#include <stdint.h>

uint64_t harness_read_isr_el1(void);
void harness_flush_dcache_range(uintptr_t addr, size_t size);
void harness_dsbsy(void);

static inline uint64_t read_isr_el1(void)
{
\treturn harness_read_isr_el1();
}

static inline void flush_dcache_range(uintptr_t addr, size_t size)
{
\tharness_flush_dcache_range(addr, size);
}

static inline void dsbsy(void)
{
\tharness_dsbsy();
}

#endif
""",
    "drivers/delay_timer.h": """\
#ifndef DELAY_TIMER_H
#define DELAY_TIMER_H

#include <stdint.h>

void harness_udelay(uint32_t usec);

static inline void udelay(uint32_t usec)
{
\tharness_udelay(usec);
}

#endif
""",
    "plat/common/platform.h": """\
#ifndef PLATFORM_H
#define PLATFORM_H

unsigned int plat_my_core_pos(void);

#endif
""",
    "tegra_private.h": """\
#ifndef TEGRA_PRIVATE_H
#define TEGRA_PRIVATE_H

#include <stdbool.h>
#include <stdint.h>

typedef struct plat_params_from_bl2 {
\tuint64_t tzdram_size;
\tuint64_t tzdram_base;
} plat_params_from_bl2_t;

plat_params_from_bl2_t *bl31_get_plat_params(void);

#endif
""",
}

HARNESS_C = r"""
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <bpmp.h>
#include <lib/psci/psci.h>
#include <pmc.h>
#include <tegra_def.h>
#include <tegra_private.h>

/* External production signatures from sc7.c (must stay unchanged). */
extern void tegra_lite_sc7_cancel(void);
extern bool tegra_lite_sc7_is_armed(void);
extern void tegra_lite_sc7_commit(void);
extern void tegra_lite_sc7_abort(void);
extern bool tegra_lite_sc7_is_aborted(void);
extern bool tegra_lite_sc7_consume_aborted(void);
extern bool tegra_lite_sc7_wake_pending(void);
extern int32_t tegra_lite_sc7_preflight(void);
extern int32_t tegra_lite_sc7_prepare(void);
extern void tegra_lite_gic_pcpu_invalidate(unsigned int cpu);
extern void tegra_lite_gic_pcpu_save(unsigned int cpu);
extern void tegra_lite_gic_pcpu_restore(unsigned int cpu);
extern void tegra_lite_gic_dist_invalidate(void);
extern void tegra_lite_gic_dist_save(void);
extern void tegra_lite_gic_dist_restore(void);

/* PMC offsets mirrored from sc7.c for verification. */
#define H_PMC_SW_WAKE_STATUS       0x018U
#define H_PMC_COREPWRGOOD_TIMER    0x03cU
#define H_PMC_CPUPWRGOOD_TIMER     0x0c8U
#define H_PMC_CPUPWROFF_TIMER      0x0ccU
#define H_PMC_COREPWROFF_TIMER     0x0e0U
#define H_PMC_WAKE2_MASK           0x160U
#define H_PMC_WAKE2_LEVEL          0x164U
#define H_PMC_WAKE2_STATUS         0x168U
#define H_PMC_SW_WAKE2_STATUS      0x16cU

#define H_PMC_LATCH_WAKEUPS        (1U << 5)
#define H_PMC_PWRREQ_POL           (1U << 8)
#define H_PMC_PWRREQ_OE            (1U << 9)
#define H_PMC_SYSCLK_POL           (1U << 10)
#define H_PMC_SYSCLK_OE            (1U << 11)
#define H_PMC_SIDE_EFFECT_LP0      (1U << 14)
#define H_PMC_CPU_PWRREQ_POL       (1U << 15)
#define H_PMC_CPU_PWRREQ_OE        (1U << 16)
#define H_PMC_INTR_POLARITY        (1U << 17)
#define H_PMC_PMIC_WAKE            (1U << (51 - 32))

#define H_CORE_PWRGOOD_VAL         0x6c00U
#define H_CORE_PWROFF_VAL          0x05a8U

#define H_GICD_BASE                0x50041000U
#define H_GICC_BASE                0x50042000U
#define H_SYSCTR0_CNTCR            0x7000f000U
#define H_GIC_PMU_EXT_INTID        118U

#define FAIL(fmt, ...) do { \
	fprintf(stderr, "FAIL [%s:%d]: " fmt "\n", __func__, __LINE__, ##__VA_ARGS__); \
	exit(1); \
} while (0)

#define CHECK(cond, fmt, ...) do { \
	if (!(cond)) { \
		FAIL(fmt, ##__VA_ARGS__); \
	} \
} while (0)

/* ---- Hardware simulation state ---- */
static uint32_t pmc_regs[TEGRA_PMC_SIZE / 4U];
static uint32_t pmc_write_counts[TEGRA_PMC_SIZE / 4U];
static uint32_t pmc_config_ro_mask;
static uint32_t inject_wake2_status_on_mask;

static uint32_t gicd_regs[0x1000U / 4U];
static uint32_t gicc_regs[0x100U / 4U];
static uint32_t sysctr0_cntcr;

static uint32_t res_sema_sta;
static uint32_t sema_illegal_writes;
static bool in_bpmp_driver;

static unsigned int current_cpu;
static uint64_t mock_isr_el1;
static bool mock_cclk_supported = true;
static uint32_t udelay_total_us;
static uint32_t dcache_flushes;

static plat_params_from_bl2_t mock_plat_params = {
	.tzdram_base = 0xFF800000ULL,
	.tzdram_size = 0x00800000ULL,
};

enum bpmp_fault_mode {
	BPMP_FAULT_NONE = 0,
	BPMP_FAULT_TIMEOUT_UNANSWERED,
	BPMP_FAULT_TIMEOUT_LATE_ACK,
	BPMP_FAULT_RETURN_ERR,
};

struct bpmp_call_record {
	unsigned int cpu;
	int mrq;
	uint32_t arg0;
	uint32_t arg1;
	int ob_sz;
	int ib_sz;
	int32_t ret;
};

#define MAX_BPMP_LOG 64
static struct bpmp_call_record bpmp_log[MAX_BPMP_LOG];
static unsigned int bpmp_log_len;

static bool bpmp_use_sema = true;
static uint32_t bpmp_hw_suspend_mode; /* What BPMP firmware actually thinks */
static enum bpmp_fault_mode fault_enable_mode = BPMP_FAULT_NONE;
static int32_t fault_enable_err = -EIO;
static unsigned int fault_enable_count;
static bool fault_enable_still_arms_hw;

static enum bpmp_fault_mode fault_disable_mode = BPMP_FAULT_NONE;
static int32_t fault_disable_err = -EIO;
static unsigned int fault_disable_count;

/* ---- Platform hooks ---- */
unsigned int plat_my_core_pos(void)
{
	return current_cpu;
}

plat_params_from_bl2_t *bl31_get_plat_params(void)
{
	return &mock_plat_params;
}

bool tegra_lite_clocks_cclk_supported(void)
{
	return mock_cclk_supported;
}

uint64_t harness_read_isr_el1(void)
{
	return mock_isr_el1;
}

void harness_flush_dcache_range(uintptr_t addr, size_t size)
{
	(void)addr;
	(void)size;
	dcache_flushes++;
}

void harness_dsbsy(void)
{
}

void harness_udelay(uint32_t usec)
{
	udelay_total_us += usec;
}

uint32_t harness_mmio_read_32(uintptr_t addr)
{
	if ((addr >= TEGRA_PMC_BASE) && (addr < (TEGRA_PMC_BASE + TEGRA_PMC_SIZE))) {
		return pmc_regs[(addr - TEGRA_PMC_BASE) / 4U];
	}
	if ((addr >= H_GICD_BASE) && (addr < (H_GICD_BASE + sizeof(gicd_regs)))) {
		return gicd_regs[(addr - H_GICD_BASE) / 4U];
	}
	if ((addr >= H_GICC_BASE) && (addr < (H_GICC_BASE + sizeof(gicc_regs)))) {
		return gicc_regs[(addr - H_GICC_BASE) / 4U];
	}
	if (addr == H_SYSCTR0_CNTCR) {
		return sysctr0_cntcr;
	}
	if (addr == (TEGRA_RES_SEMA_BASE + STA_OFFSET)) {
		return res_sema_sta;
	}
	FAIL("unexpected mmio_read_32(0x%lx)", (unsigned long)addr);
}

void harness_mmio_write_32(uintptr_t addr, uint32_t value)
{
	if ((addr >= TEGRA_PMC_BASE) && (addr < (TEGRA_PMC_BASE + TEGRA_PMC_SIZE))) {
		uint32_t off = (uint32_t)(addr - TEGRA_PMC_BASE);
		uint32_t idx = off / 4U;

		pmc_write_counts[idx]++;
		if (off == H_PMC_WAKE2_STATUS) {
			/* Hardware W1C semantics. */
			pmc_regs[idx] &= ~value;
			return;
		}
		if ((off == PMC_CONFIG) && (pmc_config_ro_mask != 0U)) {
			uint32_t cur = pmc_regs[idx];
			pmc_regs[idx] = (cur & pmc_config_ro_mask) |
					(value & ~pmc_config_ro_mask);
			return;
		}
		pmc_regs[idx] = value;
		if ((off == H_PMC_WAKE2_MASK) &&
		    ((value & H_PMC_PMIC_WAKE) != 0U) &&
		    (inject_wake2_status_on_mask != 0U)) {
			pmc_regs[H_PMC_WAKE2_STATUS / 4U] |=
				inject_wake2_status_on_mask;
		}
		return;
	}
	if ((addr >= H_GICD_BASE) && (addr < (H_GICD_BASE + sizeof(gicd_regs)))) {
		gicd_regs[(addr - H_GICD_BASE) / 4U] = value;
		return;
	}
	if ((addr >= H_GICC_BASE) && (addr < (H_GICC_BASE + sizeof(gicc_regs)))) {
		gicc_regs[(addr - H_GICC_BASE) / 4U] = value;
		return;
	}
	if (addr == H_SYSCTR0_CNTCR) {
		sysctr0_cntcr = value;
		return;
	}
	if ((addr == (TEGRA_RES_SEMA_BASE + SET_OFFSET)) ||
	    (addr == (TEGRA_RES_SEMA_BASE + CLR_OFFSET))) {
		if (!in_bpmp_driver) {
			sema_illegal_writes++;
		}
		if (addr == (TEGRA_RES_SEMA_BASE + SET_OFFSET)) {
			res_sema_sta |= value;
		} else {
			res_sema_sta &= ~value;
		}
		return;
	}
	FAIL("unexpected mmio_write_32(0x%lx, 0x%x)", (unsigned long)addr, value);
}

/* Faithful model of pinned atf/plat/nvidia/tegra/drivers/bpmp/bpmp.c */
int32_t tegra_bpmp_send_receive_atomic(int mrq, const void *ob_data, int ob_sz,
		void *ib_data, int ib_sz)
{
	unsigned int ch = plat_my_core_pos();
	uint32_t req[2] = { 0U, 0U };
	int32_t ret = 0;
	enum bpmp_fault_mode mode = BPMP_FAULT_NONE;
	int32_t err = 0;
	bool is_enable;

	CHECK(mrq == MRQ_ENABLE_SUSPEND, "unexpected MRQ %d (invented ABI?)", mrq);
	CHECK(ob_data != NULL, "NULL ob_data");
	CHECK(ob_sz == (int)sizeof(req), "unexpected ob_sz %d", ob_sz);
	CHECK(ib_data != NULL, "NULL ib_data");
	CHECK(ib_sz == 0, "invented response payload: ib_sz=%d (pinned ABI uses 0)", ib_sz);

	memcpy(req, ob_data, sizeof(req));
	CHECK(req[1] == 0U, "unexpected MRQ_ENABLE_SUSPEND req[1]=0x%x", req[1]);
	CHECK((req[0] == TEGRA_PM_SC7) || (req[0] == 0U),
	      "unexpected MRQ_ENABLE_SUSPEND mode=%u", req[0]);
	is_enable = (req[0] != 0U);

	in_bpmp_driver = true;

	/* Mirror bpmp.c: wait for master_free(ch); never clear unanswered mailbox. */
	if (bpmp_use_sema && ((res_sema_sta & CH_MASK(ch)) != MA_FREE(ch))) {
		ret = -ETIMEDOUT;
		goto record;
	}

	if (is_enable && (fault_enable_count > 0U)) {
		fault_enable_count--;
		mode = fault_enable_mode;
		err = fault_enable_err;
	} else if (!is_enable && (fault_disable_count > 0U)) {
		fault_disable_count--;
		mode = fault_disable_mode;
		err = fault_disable_err;
	}

	if (bpmp_use_sema) {
		/* signal_slave(ch): clear CH_MASK(ch) to 0 */
		harness_mmio_write_32(TEGRA_RES_SEMA_BASE + CLR_OFFSET, CH_MASK(ch));
	}

	if (mode == BPMP_FAULT_TIMEOUT_UNANSWERED) {
		/* BPMP failed to ack; channel remains 0x0 (unanswered). */
		if (is_enable && fault_enable_still_arms_hw) {
			bpmp_hw_suspend_mode = req[0];
		}
		ret = -ETIMEDOUT;
		goto record;
	}

	if (mode == BPMP_FAULT_TIMEOUT_LATE_ACK) {
		/* BPMP acked after timeout; channel stuck at MA_ACKD(ch). */
		if (bpmp_use_sema) {
			harness_mmio_write_32(TEGRA_RES_SEMA_BASE + SET_OFFSET,
					      MA_ACKD(ch));
		}
		if (is_enable && fault_enable_still_arms_hw) {
			bpmp_hw_suspend_mode = req[0];
		}
		ret = -ETIMEDOUT;
		goto record;
	}

	if (mode == BPMP_FAULT_RETURN_ERR) {
		/* BPMP replied with non-zero p->code and bpmp.c called free_master(ch). */
		if (bpmp_use_sema) {
			harness_mmio_write_32(TEGRA_RES_SEMA_BASE + SET_OFFSET,
					      MA_ACKD(ch));
			harness_mmio_write_32(TEGRA_RES_SEMA_BASE + CLR_OFFSET,
					      MA_ACKD(ch) ^ MA_FREE(ch));
		}
		if (is_enable && fault_enable_still_arms_hw) {
			bpmp_hw_suspend_mode = req[0];
		}
		ret = err;
		goto record;
	}

	/* Normal BPMP success: apply suspend mode, ack, and free_master(ch). */
	bpmp_hw_suspend_mode = req[0];
	if (bpmp_use_sema) {
		harness_mmio_write_32(TEGRA_RES_SEMA_BASE + SET_OFFSET, MA_ACKD(ch));
		harness_mmio_write_32(TEGRA_RES_SEMA_BASE + CLR_OFFSET,
				      MA_ACKD(ch) ^ MA_FREE(ch));
	}
	ret = 0;

record:
	in_bpmp_driver = false;
	CHECK(bpmp_log_len < MAX_BPMP_LOG, "bpmp_log overflow");
	bpmp_log[bpmp_log_len].cpu = ch;
	bpmp_log[bpmp_log_len].mrq = mrq;
	bpmp_log[bpmp_log_len].arg0 = req[0];
	bpmp_log[bpmp_log_len].arg1 = req[1];
	bpmp_log[bpmp_log_len].ob_sz = ob_sz;
	bpmp_log[bpmp_log_len].ib_sz = ib_sz;
	bpmp_log[bpmp_log_len].ret = ret;
	bpmp_log_len++;
	return ret;
}

/* ---- Helpers ---- */
static void reset_pmc_write_counts(void)
{
	memset(pmc_write_counts, 0, sizeof(pmc_write_counts));
}

static uint32_t pmc_writes_for(uint32_t off)
{
	return pmc_write_counts[off / 4U];
}

static void init_valid_hardware(bool with_sema)
{
	uint32_t pmu_word = H_GIC_PMU_EXT_INTID / 32U;
	uint32_t pmu_bit = 1U << (H_GIC_PMU_EXT_INTID % 32U);

	memset(pmc_regs, 0, sizeof(pmc_regs));
	memset(pmc_write_counts, 0, sizeof(pmc_write_counts));
	memset(gicd_regs, 0, sizeof(gicd_regs));
	memset(gicc_regs, 0, sizeof(gicc_regs));
	memset(bpmp_log, 0, sizeof(bpmp_log));
	bpmp_log_len = 0U;
	pmc_config_ro_mask = 0U;
	inject_wake2_status_on_mask = 0U;
	sema_illegal_writes = 0U;
	current_cpu = 0U;
	mock_isr_el1 = 0U;
	mock_cclk_supported = true;
	bpmp_use_sema = with_sema;
	res_sema_sta = with_sema ? SIGN_OF_LIFE : 0U;
	bpmp_hw_suspend_mode = 0U;

	/* Valid Mariko warmboot / BPMP entry points in DRAM below TZDRAM. */
	pmc_regs[PMC_SECURE_SCRATCH119 / 4U] = 0x80020000U;
	pmc_regs[PMC_SCRATCH39 / 4U] = 0x80030000U;

	/* Realistic non-zero baseline PMC timers & config with unrelated bits. */
	pmc_regs[H_PMC_COREPWRGOOD_TIMER / 4U] = 0x00001234U;
	pmc_regs[H_PMC_COREPWROFF_TIMER / 4U] = 0x00005678U;
	pmc_regs[H_PMC_CPUPWRGOOD_TIMER / 4U] = 0x00009abcU;
	pmc_regs[H_PMC_CPUPWROFF_TIMER / 4U] = 0x0000def0U;
	/* Unrelated bits 18, 22 set; PWRREQ_POL & SIDE_EFFECT_LP0 set; OE bits 0; INTR_POLARITY=1. */
	pmc_regs[PMC_CONFIG / 4U] = (1U << 22) | (1U << 18) |
				    H_PMC_INTR_POLARITY |
				    H_PMC_SIDE_EFFECT_LP0 |
				    H_PMC_PWRREQ_POL;
	/* Unrelated wake bits set; PMIC_WAKE mask=0, level=1, unrelated status bit 6 set. */
	pmc_regs[H_PMC_WAKE2_MASK / 4U] = 0x000000a5U;
	pmc_regs[H_PMC_WAKE2_LEVEL / 4U] = H_PMC_PMIC_WAKE | 0x0000005aU;
	pmc_regs[H_PMC_WAKE2_STATUS / 4U] = 0x00000040U;
	pmc_regs[H_PMC_SW_WAKE_STATUS / 4U] = 0x00000011U;
	pmc_regs[H_PMC_SW_WAKE2_STATUS / 4U] = 0x00000022U;

	/* GIC distributor: 4 words, PMU_EXT (INTID 118) Group 1 & enabled. */
	gicd_regs[0x000U / 4U] = 0x3U;
	gicd_regs[0x004U / 4U] = 0x3U;
	gicd_regs[(0x080U + pmu_word * 4U) / 4U] = pmu_bit;
	gicd_regs[(0x100U + pmu_word * 4U) / 4U] = pmu_bit;
}

static void simulate_bpmp_verified_reset(void)
{
	bpmp_hw_suspend_mode = 0U;
	res_sema_sta = SIGN_OF_LIFE;
}

/* ---- Scenario 1: Happy path prepare -> commit -> warmboot -> next prepare ---- */
static void test_happy_path_commit(void)
{
	init_valid_hardware(true);
	CHECK(tegra_lite_sc7_preflight() == PSCI_E_SUCCESS, "preflight failed");
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS, "prepare failed");
	CHECK(tegra_lite_sc7_is_armed(), "CPU 0 should be armed");
	CHECK(bpmp_hw_suspend_mode == TEGRA_PM_SC7, "BPMP not armed");
	CHECK(bpmp_log_len == 1U && bpmp_log[0].arg0 == TEGRA_PM_SC7 && bpmp_log[0].ret == 0,
	      "unexpected BPMP log");

	/* PMC must be programmed with SC7 timers & bits, preserving unrelated bits. */
	CHECK(pmc_regs[H_PMC_COREPWRGOOD_TIMER / 4U] == H_CORE_PWRGOOD_VAL, "corepwrgood");
	CHECK(pmc_regs[H_PMC_COREPWROFF_TIMER / 4U] == H_CORE_PWROFF_VAL, "corepwroff");
	CHECK(pmc_regs[H_PMC_CPUPWRGOOD_TIMER / 4U] == 0U, "cpupwrgood");
	CHECK(pmc_regs[H_PMC_CPUPWROFF_TIMER / 4U] == 0U, "cpupwroff");
	CHECK((pmc_regs[PMC_CONFIG / 4U] & ((1U << 22) | (1U << 18))) == ((1U << 22) | (1U << 18)),
	      "unrelated PMC_CONFIG bits clobbered");
	CHECK((pmc_regs[H_PMC_WAKE2_MASK / 4U] & (H_PMC_PMIC_WAKE | 0xa5U)) ==
	      (H_PMC_PMIC_WAKE | 0xa5U), "WAKE2_MASK");
	CHECK((pmc_regs[H_PMC_WAKE2_LEVEL / 4U] & H_PMC_PMIC_WAKE) == 0U, "WAKE2_LEVEL PMIC");
	CHECK((pmc_regs[H_PMC_WAKE2_LEVEL / 4U] & 0x5aU) == 0x5aU, "WAKE2_LEVEL unrelated");
	/* Unrelated wake2 status bit 6 must remain set. */
	CHECK((pmc_regs[H_PMC_WAKE2_STATUS / 4U] & 0x40U) == 0x40U, "unrelated wake2 status cleared");

	tegra_lite_gic_dist_save();
	tegra_lite_sc7_commit();
	CHECK(!tegra_lite_sc7_is_armed(), "armed after commit");
	/* Commit must NOT roll back SC7 PMC programming needed for hardware entry. */
	CHECK(pmc_regs[H_PMC_COREPWRGOOD_TIMER / 4U] == H_CORE_PWRGOOD_VAL,
	      "commit unexpectedly rolled back PMC timers");

	/* Simulate SC7 resume + BPMP reboot. */
	simulate_bpmp_verified_reset();
	tegra_lite_gic_dist_restore();
	CHECK(tegra_lite_sc7_preflight() == PSCI_E_SUCCESS, "second preflight failed");
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS, "second prepare failed");
	CHECK(tegra_lite_sc7_is_armed(), "second prepare not armed");
	CHECK(sema_illegal_writes == 0U, "illegal semaphore writes");
}

/* ---- Scenario 2: Clean cancel restores owned PMC/wake bits, preserves unrelated/wake ---- */
static void test_clean_cancel_rollback(void)
{
	uint32_t orig_cfg;

	init_valid_hardware(true);
	orig_cfg = pmc_regs[PMC_CONFIG / 4U];

	CHECK(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS, "prepare failed");
	CHECK(tegra_lite_sc7_is_armed(), "should be armed");

	/* Concurrent unrelated changes & live wake status arriving while armed. */
	pmc_regs[PMC_CONFIG / 4U] |= (1U << 20);
	pmc_regs[H_PMC_WAKE2_MASK / 4U] |= (1U << 3);
	pmc_regs[H_PMC_WAKE2_LEVEL / 4U] |= (1U << 4);
	pmc_regs[H_PMC_WAKE2_STATUS / 4U] |= H_PMC_PMIC_WAKE | (1U << 7);
	pmc_regs[H_PMC_SW_WAKE_STATUS / 4U] = 0x00000100U;
	pmc_regs[H_PMC_SW_WAKE2_STATUS / 4U] = 0x00000200U;

	reset_pmc_write_counts();
	tegra_lite_sc7_cancel();

	CHECK(!tegra_lite_sc7_is_armed(), "still armed after cancel");
	CHECK(bpmp_hw_suspend_mode == 0U, "BPMP not disarmed");
	CHECK(bpmp_log_len == 2U && bpmp_log[1].arg0 == 0U && bpmp_log[1].ret == 0,
	      "disable MRQ not acked");

	/* Verify exact timer restoration. */
	CHECK(pmc_regs[H_PMC_COREPWRGOOD_TIMER / 4U] == 0x00001234U,
	      "COREPWRGOOD not restored: 0x%x", pmc_regs[H_PMC_COREPWRGOOD_TIMER / 4U]);
	CHECK(pmc_regs[H_PMC_COREPWROFF_TIMER / 4U] == 0x00005678U,
	      "COREPWROFF not restored: 0x%x", pmc_regs[H_PMC_COREPWROFF_TIMER / 4U]);
	CHECK(pmc_regs[H_PMC_CPUPWRGOOD_TIMER / 4U] == 0x00009abcU,
	      "CPUPWRGOOD not restored: 0x%x", pmc_regs[H_PMC_CPUPWRGOOD_TIMER / 4U]);
	CHECK(pmc_regs[H_PMC_CPUPWROFF_TIMER / 4U] == 0x0000def0U,
	      "CPUPWROFF not restored: 0x%x", pmc_regs[H_PMC_CPUPWROFF_TIMER / 4U]);

	/* Owned PMC_CONFIG bits restored AND concurrent bit 20 preserved. */
	CHECK(pmc_regs[PMC_CONFIG / 4U] == (orig_cfg | (1U << 20)),
	      "PMC_CONFIG mismatch: got 0x%x want 0x%x",
	      pmc_regs[PMC_CONFIG / 4U], orig_cfg | (1U << 20));

	/* Owned WAKE2_MASK/LEVEL PMIC bit restored AND concurrent bits preserved. */
	CHECK(pmc_regs[H_PMC_WAKE2_MASK / 4U] == (0x000000a5U | (1U << 3)),
	      "WAKE2_MASK mismatch: 0x%x", pmc_regs[H_PMC_WAKE2_MASK / 4U]);
	CHECK(pmc_regs[H_PMC_WAKE2_LEVEL / 4U] == (H_PMC_PMIC_WAKE | 0x0000005aU | (1U << 4)),
	      "WAKE2_LEVEL mismatch: 0x%x", pmc_regs[H_PMC_WAKE2_LEVEL / 4U]);

	/* Wake status registers MUST NOT be written or cleared on rollback. */
	CHECK(pmc_writes_for(H_PMC_WAKE2_STATUS) == 0U, "WAKE2_STATUS written on rollback");
	CHECK(pmc_writes_for(H_PMC_SW_WAKE_STATUS) == 0U, "SW_WAKE_STATUS written on rollback");
	CHECK(pmc_writes_for(H_PMC_SW_WAKE2_STATUS) == 0U, "SW_WAKE2_STATUS written on rollback");
	CHECK(pmc_regs[H_PMC_WAKE2_STATUS / 4U] == (0x40U | H_PMC_PMIC_WAKE | (1U << 7)),
	      "WAKE2_STATUS lost: 0x%x", pmc_regs[H_PMC_WAKE2_STATUS / 4U]);
	CHECK(pmc_regs[H_PMC_SW_WAKE_STATUS / 4U] == 0x00000100U, "SW_WAKE_STATUS lost");
	CHECK(pmc_regs[H_PMC_SW_WAKE2_STATUS / 4U] == 0x00000200U, "SW_WAKE2_STATUS lost");
	CHECK(sema_illegal_writes == 0U, "illegal semaphore writes");
}

/* ---- Scenario 3: Disable transport timeout (unanswered mailbox) + retry + BPMP reset ---- */
static void test_disable_timeout_unanswered_mailbox(void)
{
	uint32_t orig_cfg;
	unsigned int log_after_fail;

	init_valid_hardware(true);
	orig_cfg = pmc_regs[PMC_CONFIG / 4U];

	CHECK(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS, "prepare failed");
	CHECK(bpmp_hw_suspend_mode == TEGRA_PM_SC7, "BPMP not armed");

	/* Concurrent unrelated bit + wake status before cancel timeout. */
	pmc_regs[PMC_CONFIG / 4U] |= (1U << 21);
	pmc_regs[H_PMC_WAKE2_STATUS / 4U] |= H_PMC_PMIC_WAKE;

	/* Fault inject: disable times out, leaving channel 0 unanswered (0x0). */
	fault_disable_mode = BPMP_FAULT_TIMEOUT_UNANSWERED;
	fault_disable_count = 1U;

	reset_pmc_write_counts();
	tegra_lite_sc7_cancel();

	/* Ready-to-commit MUST drop, BPMP hardware still armed, mailbox still unanswered. */
	CHECK(!tegra_lite_sc7_is_armed(), "must not remain commit-armed after failed cancel");
	CHECK(bpmp_hw_suspend_mode == TEGRA_PM_SC7, "BPMP should still be armed in hw");
	CHECK((res_sema_sta & CH_MASK(0U)) == 0U,
	      "unanswered mailbox was modified: sema=0x%x", res_sema_sta);
	CHECK(sema_illegal_writes == 0U, "sc7.c cleared unanswered mailbox!");

	/* PMC registers MUST be restored immediately even though disable timed out. */
	CHECK(pmc_regs[H_PMC_COREPWRGOOD_TIMER / 4U] == 0x00001234U, "timer not restored on timeout");
	CHECK(pmc_regs[H_PMC_CPUPWROFF_TIMER / 4U] == 0x0000def0U, "cpu timer not restored");
	CHECK(pmc_regs[PMC_CONFIG / 4U] == (orig_cfg | (1U << 21)), "PMC_CONFIG not restored");
	CHECK(pmc_regs[H_PMC_WAKE2_MASK / 4U] == 0x000000a5U, "WAKE2_MASK not restored");
	CHECK(pmc_regs[H_PMC_WAKE2_LEVEL / 4U] == (H_PMC_PMIC_WAKE | 0x0000005aU), "WAKE2_LEVEL");
	CHECK(pmc_writes_for(H_PMC_WAKE2_STATUS) == 0U, "WAKE2_STATUS written on rollback");
	CHECK((pmc_regs[H_PMC_WAKE2_STATUS / 4U] & H_PMC_PMIC_WAKE) != 0U, "PMIC wake lost");

	/* Ownership MUST stay outstanding while mailbox is unanswered -> fail closed! */
	log_after_fail = bpmp_log_len;
	reset_pmc_write_counts();
	CHECK(tegra_lite_sc7_preflight() == PSCI_E_DENIED,
	      "preflight must fail closed while unanswered mailbox/cancel pending");
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_DENIED,
	      "next prepare must fail closed while disable unacknowledged");
	CHECK(!tegra_lite_sc7_is_armed(), "armed after rejected prepare");
	CHECK(bpmp_log_len == log_after_fail,
	      "should not resend/spin on unanswered mailbox");
	CHECK(pmc_writes_for(H_PMC_COREPWRGOOD_TIMER) == 0U &&
	      pmc_writes_for(PMC_CONFIG) == 0U &&
	      pmc_writes_for(H_PMC_WAKE2_MASK) == 0U,
	      "failed-closed prepare mutated PMC");

	/* Spurious commit / gic_dist_restore must NOT clear outstanding ownership. */
	tegra_lite_sc7_commit();
	tegra_lite_gic_dist_save();
	tegra_lite_gic_dist_restore();
	CHECK(tegra_lite_sc7_preflight() == PSCI_E_DENIED,
	      "commit/gic_restore cleared outstanding cancel ownership");

	/* Retry cancel while still unanswered: must NOT clear mailbox or rewrite PMC. */
	reset_pmc_write_counts();
	tegra_lite_sc7_cancel();
	CHECK((res_sema_sta & CH_MASK(0U)) == 0U, "retry cleared unanswered mailbox");
	CHECK(sema_illegal_writes == 0U, "illegal semaphore write on retry");
	CHECK(pmc_writes_for(PMC_CONFIG) == 0U, "retry re-wrote PMC");

	/* Late BPMP ack arrives (MA_ACKD, unconsumed): still must fail closed & not clear. */
	res_sema_sta |= MA_ACKD(0U);
	CHECK(tegra_lite_sc7_preflight() == PSCI_E_DENIED,
	      "preflight allowed unconsumed MA_ACKD channel");
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_DENIED,
	      "prepare allowed unconsumed MA_ACKD channel");
	CHECK((res_sema_sta & CH_MASK(0U)) == MA_ACKD(0U), "sc7.c cleared unconsumed MA_ACKD");
	CHECK(sema_illegal_writes == 0U, "illegal semaphore write on MA_ACKD");

	/* Verified BPMP reset restores SIGN_OF_LIFE -> retry disable gets explicit ack -> recovers. */
	simulate_bpmp_verified_reset();
	CHECK(tegra_lite_sc7_preflight() == PSCI_E_SUCCESS,
	      "preflight did not allow recovery after BPMP reset");

	reset_pmc_write_counts();
	tegra_lite_sc7_cancel();
	CHECK(bpmp_log_len == log_after_fail + 1U, "retry cancel did not send disable after reset");
	CHECK(bpmp_log[log_after_fail].arg0 == 0U && bpmp_log[log_after_fail].ret == 0,
	      "retry disable not acknowledged");
	CHECK(pmc_writes_for(PMC_CONFIG) == 0U && pmc_writes_for(H_PMC_COREPWRGOOD_TIMER) == 0U,
	      "retry cancel re-wrote already-restored PMC registers");

	/* Next SC7 request now succeeds cleanly! */
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS, "prepare failed after recovery");
	CHECK(tegra_lite_sc7_is_armed(), "not armed after recovery");
	CHECK(bpmp_hw_suspend_mode == TEGRA_PM_SC7, "BPMP not re-armed");
	CHECK(sema_illegal_writes == 0U, "illegal semaphore writes");
}

/* ---- Scenario 4A: Disable non-timeout error (-EIO) + retry cancel + next prepare ---- */
static void test_disable_error_retry_cancel(void)
{
	init_valid_hardware(true);
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS, "prepare failed");

	/* Fail 2 disable attempts with -EIO (channel returns to MA_FREE each time). */
	fault_disable_mode = BPMP_FAULT_RETURN_ERR;
	fault_disable_err = -EIO;
	fault_disable_count = 2U;

	tegra_lite_sc7_cancel();
	CHECK(!tegra_lite_sc7_is_armed(), "armed after failed cancel");
	CHECK(bpmp_hw_suspend_mode == TEGRA_PM_SC7, "hw should still be armed");
	CHECK(pmc_regs[H_PMC_COREPWRGOOD_TIMER / 4U] == 0x00001234U, "PMC not restored");

	/* Next prepare while fault STILL active must try disable, fail closed, never arm SC7! */
	reset_pmc_write_counts();
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_DENIED,
	      "prepare succeeded while disable still failing!");
	CHECK(!tegra_lite_sc7_is_armed(), "armed when disable still failed");
	CHECK(bpmp_log_len == 3U, "expected 3 BPMP calls (enable, disable fail, disable fail)");
	CHECK(bpmp_log[2].arg0 == 0U && bpmp_log[2].ret == -EIO,
	      "prepare must attempt disable (not enable!) while cancel pending");
	CHECK(pmc_writes_for(H_PMC_COREPWRGOOD_TIMER) == 0U && pmc_writes_for(PMC_CONFIG) == 0U,
	      "failed-closed prepare wrote PMC");

	/* Fault cleared: retry cancel succeeds and does NOT rewrite PMC. */
	reset_pmc_write_counts();
	tegra_lite_sc7_cancel();
	CHECK(bpmp_log_len == 4U && bpmp_log[3].arg0 == 0U && bpmp_log[3].ret == 0,
	      "retry cancel did not acknowledge disable");
	CHECK(bpmp_hw_suspend_mode == 0U, "BPMP still armed after retry ack");
	CHECK(pmc_writes_for(H_PMC_COREPWRGOOD_TIMER) == 0U && pmc_writes_for(PMC_CONFIG) == 0U,
	      "retry cancel re-wrote PMC");

	/* Next prepare succeeds cleanly. */
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS, "prepare failed after acked retry");
	CHECK(bpmp_log_len == 5U && bpmp_log[4].arg0 == TEGRA_PM_SC7 && bpmp_log[4].ret == 0,
	      "expected fresh enable after acked disable");
	CHECK(tegra_lite_sc7_is_armed(), "not armed");
}

/* ---- Scenario 4B: Disable failure followed directly by next prepare (auto-reconcile) ---- */
static void test_disable_error_next_request_reconcile(void)
{
	init_valid_hardware(true);
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS, "prepare failed");

	fault_disable_mode = BPMP_FAULT_RETURN_ERR;
	fault_disable_err = -EBUSY;
	fault_disable_count = 1U;

	tegra_lite_sc7_cancel();
	CHECK(!tegra_lite_sc7_is_armed(), "armed after failed cancel");
	CHECK(bpmp_hw_suspend_mode == TEGRA_PM_SC7, "BPMP still armed");

	/* Fault cleared: next request (preflight + prepare) MUST disarm first, then arm! */
	CHECK(tegra_lite_sc7_preflight() == PSCI_E_SUCCESS, "preflight blocked recoverable retry");
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS, "next prepare failed to recover");
	CHECK(tegra_lite_sc7_is_armed(), "not armed after recovery");
	CHECK(bpmp_log_len == 4U, "expected 4 BPMP calls (en, dis-fail, dis-ok, en-ok), got %u",
	      bpmp_log_len);
	CHECK(bpmp_log[0].arg0 == TEGRA_PM_SC7 && bpmp_log[0].ret == 0, "call 0");
	CHECK(bpmp_log[1].arg0 == 0U && bpmp_log[1].ret == -EBUSY, "call 1");
	CHECK(bpmp_log[2].arg0 == 0U && bpmp_log[2].ret == 0, "call 2 must ack disable first!");
	CHECK(bpmp_log[3].arg0 == TEGRA_PM_SC7 && bpmp_log[3].ret == 0, "call 3 must re-arm");
}

/* ---- Scenario 4C: Stubbed transport (no semaphore register modeled) timeout + retry ---- */
static void test_stubbed_transport_timeout_retry(void)
{
	init_valid_hardware(false); /* res_sema_sta == 0 (unmodeled) */
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS, "prepare failed");

	fault_disable_mode = BPMP_FAULT_TIMEOUT_UNANSWERED;
	fault_disable_count = 2U;

	tegra_lite_sc7_cancel();
	CHECK(!tegra_lite_sc7_is_armed(), "armed after stubbed timeout");
	CHECK(pmc_regs[H_PMC_COREPWRGOOD_TIMER / 4U] == 0x00001234U, "PMC not restored");

	/* Still timing out -> next prepare fails closed without sending enable. */
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_DENIED, "prepare armed despite timeout");
	CHECK(bpmp_log_len == 3U && bpmp_log[2].arg0 == 0U && bpmp_log[2].ret == -ETIMEDOUT,
	      "expected disable retry before any enable");

	/* Fault cleared -> retry cancel succeeds -> next prepare succeeds. */
	tegra_lite_sc7_cancel();
	CHECK(bpmp_log_len == 4U && bpmp_log[3].arg0 == 0U && bpmp_log[3].ret == 0,
	      "stubbed retry cancel failed");
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS, "prepare failed after stubbed recovery");
}

/* ---- Scenario 5A: Failed-prepare uncertainty (enable timeout leaves unanswered mailbox) ---- */
static void test_failed_prepare_timeout_uncertainty(void)
{
	init_valid_hardware(true);

	/* Enable times out even though BPMP actually armed internally! */
	fault_enable_mode = BPMP_FAULT_TIMEOUT_UNANSWERED;
	fault_enable_count = 1U;
	fault_enable_still_arms_hw = true;

	reset_pmc_write_counts();
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_DENIED, "prepare must fail on enable timeout");
	CHECK(!tegra_lite_sc7_is_armed(), "must not be armed after failed prepare");
	CHECK((res_sema_sta & CH_MASK(0U)) == 0U, "mailbox not left unanswered");
	CHECK(sema_illegal_writes == 0U, "illegal semaphore write");
	/* Zero PMC writes when enable failed. */
	CHECK(pmc_writes_for(H_PMC_COREPWRGOOD_TIMER) == 0U &&
	      pmc_writes_for(PMC_CONFIG) == 0U &&
	      pmc_writes_for(H_PMC_WAKE2_MASK) == 0U,
	      "failed enable mutated PMC");

	/* plat_psci_handlers.c:309 immediately calls cancel(): must not clear mailbox. */
	tegra_lite_sc7_cancel();
	CHECK((res_sema_sta & CH_MASK(0U)) == 0U, "cancel cleared unanswered mailbox");
	CHECK(sema_illegal_writes == 0U, "illegal semaphore write in cancel");

	/* Subsequent preflight & prepare must fail closed until reset + disable ack. */
	CHECK(tegra_lite_sc7_preflight() == PSCI_E_DENIED, "preflight allowed unknown ownership");
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_DENIED, "prepare allowed unknown ownership");

	/* BPMP reset restores SIGN_OF_LIFE -> next prepare MUST disarm first, then arm! */
	simulate_bpmp_verified_reset();
	fault_enable_still_arms_hw = false;
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS, "recovery prepare failed");
	CHECK(bpmp_log_len == 3U, "expected enable-timeout, disable-ok, enable-ok; got %u",
	      bpmp_log_len);
	CHECK(bpmp_log[0].arg0 == TEGRA_PM_SC7 && bpmp_log[0].ret == -ETIMEDOUT, "call 0");
	CHECK(bpmp_log[1].arg0 == 0U && bpmp_log[1].ret == 0,
	      "must explicitly ack disable after failed-prepare uncertainty!");
	CHECK(bpmp_log[2].arg0 == TEGRA_PM_SC7 && bpmp_log[2].ret == 0, "call 2");
}

/* ---- Scenario 5B: Failed-prepare uncertainty (enable returns -EIO, free channel) ---- */
static void test_failed_prepare_err_uncertainty(void)
{
	init_valid_hardware(true);

	fault_enable_mode = BPMP_FAULT_RETURN_ERR;
	fault_enable_err = -EIO;
	fault_enable_count = 1U;
	fault_enable_still_arms_hw = true;

	CHECK(tegra_lite_sc7_prepare() == PSCI_E_DENIED, "prepare must fail on -EIO");
	CHECK(!tegra_lite_sc7_is_armed(), "armed on failed prepare");
	CHECK(bpmp_hw_suspend_mode == TEGRA_PM_SC7, "simulated hw armed despite -EIO");

	/* If disable ALSO fails, next prepare MUST fail closed (never blindly re-arm!). */
	fault_disable_mode = BPMP_FAULT_RETURN_ERR;
	fault_disable_err = -EIO;
	fault_disable_count = 1U;
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_DENIED,
	      "prepare must fail closed when clearing failed-prepare uncertainty fails");
	CHECK(bpmp_log_len == 2U && bpmp_log[1].arg0 == 0U && bpmp_log[1].ret == -EIO,
	      "expected disable attempt on uncertain state");

	/* Once disable succeeds, ownership clears and prepare succeeds! */
	fault_enable_still_arms_hw = false;
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS, "recovery failed");
	CHECK(bpmp_log_len == 4U && bpmp_log[2].arg0 == 0U && bpmp_log[2].ret == 0 &&
	      bpmp_log[3].arg0 == TEGRA_PM_SC7 && bpmp_log[3].ret == 0,
	      "expected disable-ok then enable-ok");
}

/* ---- Scenario 6A: Partial-prepare rollback on PMC_CONFIG failure (before wake2 writes) ---- */
static void test_partial_prepare_pmc_config_fail(void)
{
	uint32_t orig_cfg;

	init_valid_hardware(true);
	orig_cfg = pmc_regs[PMC_CONFIG / 4U];
	/* Reject writes to PWRREQ_OE so PMC_CONFIG readback fails. */
	pmc_config_ro_mask = H_PMC_PWRREQ_OE;

	reset_pmc_write_counts();
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_DENIED, "prepare must fail on PMC_CONFIG mismatch");
	CHECK(!tegra_lite_sc7_is_armed(), "armed after PMC_CONFIG failure");
	CHECK(bpmp_hw_suspend_mode == 0U, "BPMP not disarmed on PMC_CONFIG failure");

	/* Timers & PMC_CONFIG restored; WAKE2_* and SW_WAKE* MUST have ZERO writes! */
	CHECK(pmc_regs[H_PMC_COREPWRGOOD_TIMER / 4U] == 0x00001234U, "corepwrgood not restored");
	CHECK(pmc_regs[H_PMC_COREPWROFF_TIMER / 4U] == 0x00005678U, "corepwroff not restored");
	CHECK(pmc_regs[H_PMC_CPUPWRGOOD_TIMER / 4U] == 0x00009abcU, "cpupwrgood not restored");
	CHECK(pmc_regs[H_PMC_CPUPWROFF_TIMER / 4U] == 0x0000def0U, "cpupwroff not restored");
	CHECK(pmc_regs[PMC_CONFIG / 4U] == orig_cfg,
	      "PMC_CONFIG not restored: got 0x%x want 0x%x", pmc_regs[PMC_CONFIG / 4U], orig_cfg);
	CHECK(pmc_writes_for(H_PMC_WAKE2_MASK) == 0U, "WAKE2_MASK touched before wake stage");
	CHECK(pmc_writes_for(H_PMC_WAKE2_LEVEL) == 0U, "WAKE2_LEVEL touched before wake stage");
	CHECK(pmc_writes_for(H_PMC_WAKE2_STATUS) == 0U, "WAKE2_STATUS touched before wake stage");
	CHECK(pmc_writes_for(H_PMC_SW_WAKE_STATUS) == 0U, "SW_WAKE_STATUS touched");
	CHECK(pmc_writes_for(H_PMC_SW_WAKE2_STATUS) == 0U, "SW_WAKE2_STATUS touched");
}

/* ---- Scenario 6B: Wake arrives at end of prepare + disable fails ---- */
static void test_prepare_late_wake_and_disable_fail(void)
{
	uint32_t orig_cfg;

	init_valid_hardware(true);
	orig_cfg = pmc_regs[PMC_CONFIG / 4U];
	/* Power button fires right as WAKE2_MASK enables PMIC wake, AND disable fails! */
	inject_wake2_status_on_mask = H_PMC_PMIC_WAKE;
	fault_disable_mode = BPMP_FAULT_RETURN_ERR;
	fault_disable_err = -EIO;
	fault_disable_count = 1U;

	CHECK(tegra_lite_sc7_prepare() == PSCI_E_DENIED, "prepare must fail on late PMIC wake");
	CHECK(!tegra_lite_sc7_is_armed(), "armed after late PMIC wake");
	/* PMC restored, live PMIC wake & unrelated bit 6 preserved in WAKE2_STATUS! */
	CHECK(pmc_regs[H_PMC_COREPWRGOOD_TIMER / 4U] == 0x00001234U, "timer not restored");
	CHECK(pmc_regs[PMC_CONFIG / 4U] == orig_cfg, "PMC_CONFIG not restored");
	CHECK(pmc_regs[H_PMC_WAKE2_MASK / 4U] == 0x000000a5U, "WAKE2_MASK not restored");
	CHECK(pmc_regs[H_PMC_WAKE2_LEVEL / 4U] == (H_PMC_PMIC_WAKE | 0x0000005aU), "WAKE2_LEVEL");
	CHECK(pmc_regs[H_PMC_WAKE2_STATUS / 4U] == (0x40U | H_PMC_PMIC_WAKE),
	      "late PMIC wake status cleared during rollback: 0x%x",
	      pmc_regs[H_PMC_WAKE2_STATUS / 4U]);

	/* Ownership is STILL pending (disable failed!) -> next prepare disarms first. */
	inject_wake2_status_on_mask = 0U;
	pmc_regs[H_PMC_WAKE2_STATUS / 4U] = 0x40U;
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS, "recovery prepare failed");
	CHECK(bpmp_log_len == 4U && bpmp_log[1].arg0 == 0U && bpmp_log[1].ret == -EIO &&
	      bpmp_log[2].arg0 == 0U && bpmp_log[2].ret == 0 &&
	      bpmp_log[3].arg0 == TEGRA_PM_SC7 && bpmp_log[3].ret == 0,
	      "ownership lost after late-wake cancel failure");
}

/* ---- Scenario 7A: Interleaved cores cannot steal/clear CPU 0 ownership or abort state ---- */
static void test_interleaved_cores_isolation(void)
{
	unsigned int log_before_cpu1;

	init_valid_hardware(true);

	/* CPU 0 prepares SC7. */
	current_cpu = 0U;
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS, "CPU 0 prepare failed");
	CHECK(tegra_lite_sc7_is_armed(), "CPU 0 should be armed");
	log_before_cpu1 = bpmp_log_len;

	/* CPU 1 tries every SC7 entry point while CPU 0 is armed. */
	current_cpu = 1U;
	reset_pmc_write_counts();
	CHECK(!tegra_lite_sc7_is_armed(), "CPU 1 must NOT see is_armed()==true");
	CHECK(tegra_lite_sc7_preflight() == PSCI_E_DENIED,
	      "CPU 1 preflight must fail while CPU 0 armed");
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_DENIED, "CPU 1 prepare must fail");
	tegra_lite_sc7_cancel();
	tegra_lite_sc7_commit();
	tegra_lite_sc7_abort();

	/* CPU 1 must NOT have touched BPMP, PMC, or CPU 0's armed/abort state. */
	CHECK(bpmp_log_len == log_before_cpu1, "CPU 1 sent BPMP MRQ on channel 1!");
	CHECK(pmc_writes_for(H_PMC_COREPWRGOOD_TIMER) == 0U &&
	      pmc_writes_for(PMC_CONFIG) == 0U &&
	      pmc_writes_for(H_PMC_WAKE2_MASK) == 0U,
	      "CPU 1 mutated CPU 0's PMC state!");
	CHECK(!tegra_lite_sc7_is_aborted(), "CPU 1 set shared abort state");

	/* Back on CPU 0: still armed and intact; now abort with disable failure. */
	current_cpu = 0U;
	CHECK(tegra_lite_sc7_is_armed(), "CPU 1 cleared CPU 0 armed state!");
	fault_disable_mode = BPMP_FAULT_RETURN_ERR;
	fault_disable_err = -EIO;
	fault_disable_count = 1U;
	tegra_lite_sc7_abort();

	CHECK(!tegra_lite_sc7_is_armed(), "still armed after abort");
	CHECK(tegra_lite_sc7_is_aborted(), "abort flag not set");
	CHECK(pmc_regs[H_PMC_COREPWRGOOD_TIMER / 4U] == 0x00001234U, "abort did not restore PMC");

	/* CPU 1 & CPU 2 wake up before CPU 0 and call consume_aborted() (tegra_pm.c:201). */
	current_cpu = 1U;
	CHECK(tegra_lite_sc7_consume_aborted() == true,
	      "CPU 1 must observe aborted=true so tegra_pm.c downgrades to RUN");
	CHECK(tegra_lite_sc7_is_aborted() == true,
	      "CPU 1 CLEARED shared abort state from an unrelated core!");
	/* CPU 1 calling prepare/commit/cancel must ALSO not clear abort state or BPMP ownership. */
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_DENIED, "CPU 1 prepare must fail");
	tegra_lite_sc7_commit();
	tegra_lite_sc7_cancel();
	CHECK(tegra_lite_sc7_is_aborted() == true, "CPU 1 ops cleared shared abort state!");

	current_cpu = 2U;
	CHECK(tegra_lite_sc7_consume_aborted() == true, "CPU 2 must observe aborted=true");
	CHECK(tegra_lite_sc7_is_aborted() == true, "CPU 2 cleared shared abort state!");

	/* CPU 0 wakes up: consumes AND clears shared abort state; BPMP ownership stays pending! */
	current_cpu = 0U;
	CHECK(tegra_lite_sc7_consume_aborted() == true, "CPU 0 must consume abort");
	CHECK(tegra_lite_sc7_is_aborted() == false, "CPU 0 failed to clear own abort state");
	CHECK(tegra_lite_sc7_consume_aborted() == false, "second consume on CPU 0 must be false");

	/* BPMP ownership must STILL be pending from the failed disable during abort. */
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS, "CPU 0 recovery failed");
	CHECK(bpmp_log_len == 4U && bpmp_log[2].arg0 == 0U && bpmp_log[2].ret == 0 &&
	      bpmp_log[3].arg0 == TEGRA_PM_SC7 && bpmp_log[3].ret == 0,
	      "abort consume lost pending BPMP ownership");
}

/* ---- Scenario 7B: Full PSCI select/suspend/abort/wfi/resume + C7 idle preservation ---- */
static void test_psci_callsite_flow_and_c7_idle(void)
{
	bool entered_soc_powerdn;
	bool entered_cpu_c7;
	unsigned int wakeup_lvl2_state;

	init_valid_hardware(true);

	/*
	 * Transition 1 on CPU 0:
	 * validate_power_state -> get_target_pwr_state -> pwr_domain_suspend (SE fails -> abort)
	 * with disable transport timeout leaving channel 0 unanswered!
	 */
	current_cpu = 0U;
	CHECK(tegra_lite_sc7_preflight() == PSCI_E_SUCCESS, "T1 preflight");
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS, "T1 prepare");
	CHECK(tegra_lite_sc7_is_armed(), "T1 lvl2 check");
	tegra_lite_gic_dist_save();

	/* Simulate tegra_se_suspend() failure in tegra_soc_pwr_domain_suspend: */
	fault_disable_mode = BPMP_FAULT_TIMEOUT_UNANSWERED;
	fault_disable_count = 1U;
	tegra_lite_gic_dist_invalidate();
	tegra_lite_sc7_abort();

	/* Simulate tegra_pwr_domain_power_down_wfi + tegra_soc_pwr_domain_power_down_wfi: */
	entered_soc_powerdn = tegra_lite_sc7_is_armed();
	CHECK(!entered_soc_powerdn, "aborted transition must NOT enter SC7 in power_down_wfi!");
	/* Falls back to C7 (tegra_fc_cpu_powerdn). */
	entered_cpu_c7 = !entered_soc_powerdn;
	CHECK(entered_cpu_c7, "must degrade to C7");

	/* CPU 1 wakes up first with stale PSCI lvl2 == PSTATE_ID_SOC_POWERDN: */
	current_cpu = 1U;
	wakeup_lvl2_state = PSTATE_ID_SOC_POWERDN;
	if (tegra_lite_sc7_consume_aborted()) {
		wakeup_lvl2_state = 0U; /* PSCI_LOCAL_STATE_RUN */
	}
	CHECK(wakeup_lvl2_state == 0U, "CPU 1 would have panicked in SC7 resume");
	CHECK(tegra_lite_sc7_is_aborted(), "CPU 1 must not clear CPU 0 abort flag");

	/* CPU 0 wakes up: */
	current_cpu = 0U;
	wakeup_lvl2_state = PSTATE_ID_SOC_POWERDN;
	if (tegra_lite_sc7_consume_aborted()) {
		wakeup_lvl2_state = 0U;
	}
	CHECK(wakeup_lvl2_state == 0U, "CPU 0 must downgrade aborted SC7 wakeup");
	CHECK(!tegra_lite_sc7_is_aborted(), "CPU 0 must clear abort flag");

	/* Transition 2 while BPMP mailbox is STILL unanswered:
	 * - Deep SC7 transition fails closed at validate_power_state (preflight == DENIED).
	 * - Normal CPU-level idle (PSTATE_ID_CORE_POWERDN: pcpu_save -> C7 -> pcpu_restore) works!
	 */
	CHECK(tegra_lite_sc7_preflight() == PSCI_E_DENIED,
	      "deep transition must fail closed while BPMP mailbox unanswered");
	tegra_lite_gic_pcpu_save(0U);
	tegra_lite_gic_pcpu_restore(0U);
	tegra_lite_gic_pcpu_save(1U);
	tegra_lite_gic_pcpu_restore(1U);

	/* After verified BPMP reset, Transition 3 recovers and commits SC7 cleanly. */
	simulate_bpmp_verified_reset();
	CHECK(tegra_lite_sc7_preflight() == PSCI_E_SUCCESS, "T3 preflight");
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS, "T3 prepare");
	CHECK(tegra_lite_sc7_is_armed(), "T3 armed");
	tegra_lite_gic_dist_save();
	tegra_lite_sc7_commit();
	CHECK(!tegra_lite_sc7_is_armed(), "T3 committed");
	simulate_bpmp_verified_reset();
	tegra_lite_gic_dist_restore();
	CHECK(sema_illegal_writes == 0U, "illegal semaphore writes");
}

/* ---- Scenario 8: Re-entrant prepare while already armed must not clobber baseline ---- */
static void test_reentrant_prepare_preserves_baseline(void)
{
	uint32_t orig_cfg;

	init_valid_hardware(true);
	orig_cfg = pmc_regs[PMC_CONFIG / 4U];

	CHECK(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS, "first prepare failed");
	CHECK(tegra_lite_sc7_is_armed(), "not armed");

	/* Unexpected second prepare while armed must fail closed and preserve original snapshot. */
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_DENIED, "re-entrant prepare must fail closed");
	CHECK(tegra_lite_sc7_is_armed(), "re-entrant prepare clobbered active armed state");

	/* Now cancel: must restore the ORIGINAL pre-first-prepare PMC baseline! */
	tegra_lite_sc7_cancel();
	CHECK(!tegra_lite_sc7_is_armed(), "still armed after cancel");
	CHECK(pmc_regs[H_PMC_COREPWRGOOD_TIMER / 4U] == 0x00001234U,
	      "baseline timer clobbered by re-entrant prepare");
	CHECK(pmc_regs[PMC_CONFIG / 4U] == orig_cfg,
	      "baseline PMC_CONFIG clobbered by re-entrant prepare");
	CHECK(pmc_regs[H_PMC_WAKE2_MASK / 4U] == 0x000000a5U,
	      "baseline WAKE2_MASK clobbered");
	CHECK(pmc_regs[H_PMC_WAKE2_LEVEL / 4U] == (H_PMC_PMIC_WAKE | 0x0000005aU),
	      "baseline WAKE2_LEVEL clobbered");
}

/* ---- Scenario 9: Disarmed cancel is a strict no-op ---- */
static void test_disarmed_cancel_noop(void)
{
	init_valid_hardware(true);
	reset_pmc_write_counts();
	tegra_lite_sc7_cancel();
	CHECK(bpmp_log_len == 0U, "disarmed cancel sent BPMP MRQ");
	CHECK(pmc_writes_for(PMC_CONFIG) == 0U &&
	      pmc_writes_for(H_PMC_COREPWRGOOD_TIMER) == 0U &&
	      pmc_writes_for(H_PMC_WAKE2_MASK) == 0U &&
	      pmc_writes_for(H_PMC_WAKE2_LEVEL) == 0U,
	      "disarmed cancel wrote PMC");
}

/* ---- Scenario 10: wake_pending scoping across states and CPUs ---- */
static void test_wake_pending_scoping(void)
{
	init_valid_hardware(true);

	/* Stale PMIC_WAKE in WAKE2_STATUS before arming must NOT trip wake_pending. */
	pmc_regs[H_PMC_WAKE2_STATUS / 4U] |= H_PMC_PMIC_WAKE;
	CHECK(!tegra_lite_sc7_wake_pending(), "stale WAKE2_STATUS tripped while disarmed");

	/* Prepare clears stale PMIC_WAKE and arms WAKE2; now live PMIC_WAKE must trip on CPU 0. */
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS, "prepare failed");
	CHECK(!tegra_lite_sc7_wake_pending(), "unexpected wake_pending after clean prepare");

	pmc_regs[H_PMC_WAKE2_STATUS / 4U] |= H_PMC_PMIC_WAKE;
	CHECK(tegra_lite_sc7_wake_pending(), "live PMIC_WAKE missed while armed on CPU 0");
	current_cpu = 1U;
	CHECK(!tegra_lite_sc7_wake_pending(), "CPU 1 should not use CPU 0's armed wake2 state");
	current_cpu = 0U;

	/* After failed cancel (CANCEL_PENDING), WAKE2_STATUS is preserved and no longer armed. */
	fault_disable_mode = BPMP_FAULT_RETURN_ERR;
	fault_disable_err = -EIO;
	fault_disable_count = 1U;
	tegra_lite_sc7_cancel();
	CHECK((pmc_regs[H_PMC_WAKE2_STATUS / 4U] & H_PMC_PMIC_WAKE) != 0U, "PMIC wake cleared");
	CHECK(!tegra_lite_sc7_wake_pending(), "CANCEL_PENDING should not treat wake2 as armed");

	/* GIC PMU_EXT pending & ISR_EL1 still work on any CPU. */
	mock_isr_el1 = 1U;
	CHECK(tegra_lite_sc7_wake_pending(), "ISR_EL1 missed");
	mock_isr_el1 = 0U;
	gicd_regs[(0x200U + (H_GIC_PMU_EXT_INTID / 32U) * 4U) / 4U] =
		1U << (H_GIC_PMU_EXT_INTID % 32U);
	CHECK(tegra_lite_sc7_wake_pending(), "GICD ISPENDR PMU_EXT missed");
}

/* ---- Scenario 11: Unrelated core cannot touch pending/unknown BPMP ownership ---- */
static void test_unrelated_core_during_pending_cancel(void)
{
	unsigned int log_after_fail;

	init_valid_hardware(true);
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS, "prepare failed");

	fault_disable_mode = BPMP_FAULT_RETURN_ERR;
	fault_disable_err = -EIO;
	fault_disable_count = 1U;
	tegra_lite_sc7_cancel();
	log_after_fail = bpmp_log_len;

	/* CPU 1 attempts cancel/prepare/commit/abort while CPU 0 owns CANCEL_PENDING. */
	current_cpu = 1U;
	reset_pmc_write_counts();
	tegra_lite_sc7_cancel();
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_DENIED, "CPU 1 prepare succeeded");
	tegra_lite_sc7_commit();
	tegra_lite_sc7_abort();
	CHECK(bpmp_log_len == log_after_fail, "CPU 1 sent BPMP MRQ during CPU 0 CANCEL_PENDING");
	CHECK(pmc_writes_for(PMC_CONFIG) == 0U, "CPU 1 wrote PMC during CPU 0 CANCEL_PENDING");
	CHECK(!tegra_lite_sc7_is_aborted(), "CPU 1 set abort flag");

	/* Back on CPU 0: ownership is STILL pending -> next prepare must disarm first! */
	current_cpu = 0U;
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS, "CPU 0 recovery failed");
	CHECK(bpmp_log_len == log_after_fail + 2U, "expected disable-ok then enable-ok");
	CHECK(bpmp_log[log_after_fail].cpu == 0U && bpmp_log[log_after_fail].arg0 == 0U &&
	      bpmp_log[log_after_fail].ret == 0, "CPU 0 must ack disable first");
	CHECK(bpmp_log[log_after_fail + 1U].cpu == 0U &&
	      bpmp_log[log_after_fail + 1U].arg0 == TEGRA_PM_SC7 &&
	      bpmp_log[log_after_fail + 1U].ret == 0, "CPU 0 enable");
}

/* ---- Scenario 12: BPMP dies to 0x0 semaphore during cancel timeout ---- */
static void test_bpmp_crash_to_zero_sema(void)
{
	unsigned int log_after_fail;

	init_valid_hardware(true);
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS, "prepare failed");

	/* Disable times out and BPMP semaphore drops completely to 0. */
	fault_disable_mode = BPMP_FAULT_TIMEOUT_UNANSWERED;
	fault_disable_count = 1U;
	tegra_lite_sc7_cancel();
	res_sema_sta = 0U;
	log_after_fail = bpmp_log_len;

	/* Must fail closed immediately without spinning on BPMP until SIGN_OF_LIFE returns. */
	CHECK(tegra_lite_sc7_preflight() == PSCI_E_DENIED, "preflight allowed dead BPMP");
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_DENIED, "prepare allowed dead BPMP");
	CHECK(bpmp_log_len == log_after_fail, "called BPMP while semaphore dead");

	/* BPMP reboots -> SIGN_OF_LIFE returns -> disable ack clears ownership. */
	simulate_bpmp_verified_reset();
	CHECK(tegra_lite_sc7_preflight() == PSCI_E_SUCCESS, "preflight blocked after reset");
	CHECK(tegra_lite_sc7_prepare() == PSCI_E_SUCCESS, "recovery failed after BPMP reboot");
	CHECK(bpmp_log_len == log_after_fail + 2U &&
	      bpmp_log[log_after_fail].arg0 == 0U && bpmp_log[log_after_fail].ret == 0 &&
	      bpmp_log[log_after_fail + 1U].arg0 == TEGRA_PM_SC7 &&
	      bpmp_log[log_after_fail + 1U].ret == 0,
	      "must ack disable before re-enabling after BPMP reboot");
}

struct scenario {
	const char *name;
	void (*fn)(void);
};

static const struct scenario scenarios[] = {
	{ "happy_path_commit", test_happy_path_commit },
	{ "clean_cancel_rollback", test_clean_cancel_rollback },
	{ "disable_timeout_unanswered_mailbox", test_disable_timeout_unanswered_mailbox },
	{ "disable_error_retry_cancel", test_disable_error_retry_cancel },
	{ "disable_error_next_request_reconcile", test_disable_error_next_request_reconcile },
	{ "stubbed_transport_timeout_retry", test_stubbed_transport_timeout_retry },
	{ "failed_prepare_timeout_uncertainty", test_failed_prepare_timeout_uncertainty },
	{ "failed_prepare_err_uncertainty", test_failed_prepare_err_uncertainty },
	{ "partial_prepare_pmc_config_fail", test_partial_prepare_pmc_config_fail },
	{ "prepare_late_wake_and_disable_fail", test_prepare_late_wake_and_disable_fail },
	{ "interleaved_cores_isolation", test_interleaved_cores_isolation },
	{ "psci_callsite_flow_and_c7_idle", test_psci_callsite_flow_and_c7_idle },
	{ "reentrant_prepare_preserves_baseline", test_reentrant_prepare_preserves_baseline },
	{ "disarmed_cancel_noop", test_disarmed_cancel_noop },
	{ "wake_pending_scoping", test_wake_pending_scoping },
	{ "unrelated_core_during_pending_cancel", test_unrelated_core_during_pending_cancel },
	{ "bpmp_crash_to_zero_sema", test_bpmp_crash_to_zero_sema },
};

int main(int argc, char **argv)
{
	if (argc != 2) {
		fprintf(stderr, "usage: %s <scenario>\n", argv[0]);
		return 2;
	}
	for (size_t i = 0; i < ARRAY_SIZE(scenarios); i++) {
		if (strcmp(argv[1], scenarios[i].name) == 0) {
			scenarios[i].fn();
			return 0;
		}
	}
	fprintf(stderr, "unknown scenario: %s\n", argv[1]);
	return 2;
}
"""

SCENARIO_NAMES = [
    "happy_path_commit",
    "clean_cancel_rollback",
    "disable_timeout_unanswered_mailbox",
    "disable_error_retry_cancel",
    "disable_error_next_request_reconcile",
    "stubbed_transport_timeout_retry",
    "failed_prepare_timeout_uncertainty",
    "failed_prepare_err_uncertainty",
    "partial_prepare_pmc_config_fail",
    "prepare_late_wake_and_disable_fail",
    "interleaved_cores_isolation",
    "psci_callsite_flow_and_c7_idle",
    "reentrant_prepare_preserves_baseline",
    "disarmed_cancel_noop",
    "wake_pending_scoping",
    "unrelated_core_during_pending_cancel",
    "bpmp_crash_to_zero_sema",
]

REQUIRED_SIGNATURES = [
    r"\bvoid\s+tegra_lite_sc7_cancel\s*\(\s*void\s*\)",
    r"\bbool\s+tegra_lite_sc7_is_armed\s*\(\s*void\s*\)",
    r"\bvoid\s+tegra_lite_sc7_commit\s*\(\s*void\s*\)",
    r"\bvoid\s+tegra_lite_sc7_abort\s*\(\s*void\s*\)",
    r"\bbool\s+tegra_lite_sc7_is_aborted\s*\(\s*void\s*\)",
    r"\bbool\s+tegra_lite_sc7_consume_aborted\s*\(\s*void\s*\)",
    r"\bbool\s+tegra_lite_sc7_wake_pending\s*\(\s*void\s*\)",
    r"\bint32_t\s+tegra_lite_sc7_preflight\s*\(\s*void\s*\)",
    r"\bint32_t\s+tegra_lite_sc7_prepare\s*\(\s*void\s*\)",
    r"\bvoid\s+tegra_lite_gic_pcpu_invalidate\s*\(\s*unsigned\s+int\s+\w+\s*\)",
    r"\bvoid\s+tegra_lite_gic_pcpu_save\s*\(\s*unsigned\s+int\s+\w+\s*\)",
    r"\bvoid\s+tegra_lite_gic_pcpu_restore\s*\(\s*unsigned\s+int\s+\w+\s*\)",
    r"\bvoid\s+tegra_lite_gic_dist_invalidate\s*\(\s*void\s*\)",
    r"\bvoid\s+tegra_lite_gic_dist_save\s*\(\s*void\s*\)",
    r"\bvoid\s+tegra_lite_gic_dist_restore\s*\(\s*void\s*\)",
]


def find_compiler() -> str:
    for candidate in ("cc", "clang", "gcc"):
        path = shutil.which(candidate)
        if path:
            return path
    raise RuntimeError("No host C compiler (cc/clang/gcc) found in PATH")


def check_static_invariants(atf_root: Path) -> list[str]:
    failures: list[str] = []
    sc7_path = atf_root / "plat/nvidia/tegra/soc/t210/t214/sc7.c"
    bpmp_path = atf_root / "plat/nvidia/tegra/drivers/bpmp/bpmp.c"
    sc7_src = sc7_path.read_text(encoding="utf-8")
    bpmp_src = bpmp_path.read_text(encoding="utf-8")

    # Verify pinned BPMP ABI in bpmp.c matches harness assumptions.
    if "ret = p->code;" not in bpmp_src or "free_master(ch);" not in bpmp_src:
        failures.append("pinned bpmp.c does not match expected return/free_master ABI")

    # Verify all external function signatures in sc7.c remain intact.
    for pattern in REQUIRED_SIGNATURES:
        if not re.search(pattern, sc7_src):
            failures.append(f"missing or altered external signature matching: {pattern}")

    # Verify sc7.c never discards tegra_bpmp_send_receive_atomic return value.
    if re.search(r"\(\s*void\s*\)\s*tegra_bpmp_send_receive_atomic\s*\(", sc7_src):
        failures.append("sc7.c still discards tegra_bpmp_send_receive_atomic return code")

    # Verify sc7.c never writes TEGRA_RES_SEMA_BASE SET_OFFSET / CLR_OFFSET.
    if re.search(r"TEGRA_RES_SEMA_BASE\s*\+\s*(SET_OFFSET|CLR_OFFSET)", sc7_src):
        failures.append("sc7.c directly writes TEGRA_RES_SEMA_BASE SET/CLR (must not clear mailbox)")

    return failures


def run_suite(atf_root: Path) -> int:
    sc7_path = atf_root / "plat/nvidia/tegra/soc/t210/t214/sc7.c"
    if not sc7_path.is_file():
        print(f"ERROR: missing {sc7_path}", file=sys.stderr)
        return 2

    compiler = find_compiler()
    static_failures = check_static_invariants(atf_root)

    with tempfile.TemporaryDirectory(prefix="t214-sc7-cancel-") as tmp:
        tmp_path = Path(tmp)
        inc_dir = tmp_path / "mock_inc"
        for rel, content in MOCK_HEADERS.items():
            dest = inc_dir / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_text(content, encoding="utf-8")

        harness_c = tmp_path / "harness.c"
        harness_c.write_text(HARNESS_C, encoding="utf-8")
        harness_bin = tmp_path / "harness"

        cmd = [
            compiler,
            "-std=c11",
            "-O2",
            "-Wall",
            "-Wextra",
            "-Wshadow",
            "-Werror",
            f"-I{inc_dir}",
            f"-I{atf_root / 'plat/nvidia/tegra/include/drivers'}",
            f"-I{atf_root / 'plat/nvidia/tegra/include/t210'}",
            str(sc7_path),
            str(harness_c),
            "-o",
            str(harness_bin),
        ]
        build = subprocess.run(cmd, capture_output=True, text=True)
        if build.returncode != 0:
            print("BUILD FAILED:", " ".join(cmd), file=sys.stderr)
            if build.stdout:
                print(build.stdout, file=sys.stderr)
            if build.stderr:
                print(build.stderr, file=sys.stderr)
            return 1

        passed = 0
        failed = 0
        for name in SCENARIO_NAMES:
            proc = subprocess.run([str(harness_bin), name], capture_output=True, text=True)
            if proc.returncode == 0:
                print(f"PASS {name}")
                passed += 1
            else:
                detail = (proc.stderr or proc.stdout).strip()
                print(f"FAIL {name}: {detail}")
                failed += 1

    if not static_failures:
        print("PASS static_invariants")
        passed += 1
    else:
        for msg in static_failures:
            print(f"FAIL static: {msg}")
            failed += 1

    total = passed + failed
    print(f"SUMMARY: {passed}/{total} checks passed, {failed} failed")
    return 0 if failed == 0 else 1


def main(argv: list[str]) -> int:
    atf_arg = argv[1] if len(argv) > 1 else "atf"
    return run_suite(Path(atf_arg).resolve())


if __name__ == "__main__":
    sys.exit(main(sys.argv))
