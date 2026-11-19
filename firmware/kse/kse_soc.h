/* KSE SoC memory map shared by the firmware and the testbench
 * (tb/kse_soc/tb_kse_soc.sv mirrors these values as localparams). */
#ifndef KSE_SOC_H
#define KSE_SOC_H
#include <stdint.h>

#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))

/* ---- shared SRAM (512 KiB at 0x4000_0000); offsets inside the window ---- */
#define SHRAM_BASE        0x40000000u
#define SH_IN_OFF         0x00000u   /* 1584-word input, written by the loader  */
#define SH_PARAM_OFF      0x018C0u   /* parameter stream v3, follows the input */
#define KSE_LAYER_WORDS   6584u
#define KSE_LAYER_BYTES   (KSE_LAYER_WORDS * 4u)
#define KSE_LAYERS        12u
#define SH_OUT_OFF        0x60000u   /* 1584-word output, written by the DMA   */
#define SH_FLAG_START     0x7F000u   /* firmware -> loader: start loading      */
#define SH_FLAG_DONE      0x7F004u   /* firmware: task complete (window end)   */
#define SH(o)             REG32(SHRAM_BASE + (o))

#define FLAG_START_VALUE  0x00000001u
#define FLAG_DONE_PASS    0x600D000Cu  /* 12 layers completed, no error         */
#define FLAG_DONE_FAIL    0xBAD00000u  /* | error bits                          */

/* ---- KSE engine MMIO (PPI O12 slot, 4 KiB) ---- */
#define KSE_BASE          0x11000000u
#define KSE(o)            REG32(KSE_BASE + (o))
#define KSE_ID            0x000u
#define KSE_CTRL          0x004u
#define KSE_STATUS        0x008u
#define KSE_IRQ_STATUS    0x00Cu
#define KSE_PARAM_ADDR    0x010u
#define KSE_PARAM_LEN     0x014u
#define KSE_IN_ADDR       0x018u
#define KSE_OUT_ADDR      0x01Cu
#define KSE_CMD           0x020u
#define KSE_LDR_WPTR      0x024u
#define KSE_LDR_BASE      0x028u
#define KSE_DONE_CNT      0x02Cu
#define KSE_ERR           0x030u
#define KSE_ID_VALUE      0x4B534531u
#define KSE_CMD_IN_EN     (1u << 8)
#define KSE_CMD_OUT_EN    (1u << 9)
#define KSE_STATUS_WORK   (1u << 1)
#define KSE_STATUS_QFULL  (1u << 4)

/* ---- PLIC ---- */
#define PLIC_BASE         0x0C000000u
#define PLIC_PRIO(id)     REG32(PLIC_BASE + 4u * (id))
#define PLIC_ENABLE0      REG32(PLIC_BASE + 0x2000u)
#define PLIC_THRESHOLD    REG32(PLIC_BASE + 0x200000u)
#define PLIC_CLAIM        REG32(PLIC_BASE + 0x200004u)
#define KSE_IRQ_ID        17u

#endif
