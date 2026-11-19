/* KSE SoC firmware: E203 schedules the 12 KWT-1 encoder layers on the KSE
 * engine.  Command queue depth 2: layers 0 and 1 are issued at start, and the
 * layer-done interrupt for layer L issues layer L+2, so layer L+1 is always
 * queued while layer L computes.  Between interrupts the core sleeps in WFI.
 *
 * Shared SRAM flags (see kse_soc.h): FLAG_START tells the testbench loader to
 * begin writing the input and parameters; FLAG_DONE ends the measured window
 * (after the last layer's output write-back has been acknowledged). */
#include <stdint.h>
#include "kse_soc.h"

static volatile uint32_t seen;      /* layers reported done */
static volatile uint32_t issued;    /* layers issued        */
static volatile uint32_t irq_cnt;
static volatile uint32_t bad;

static void issue(uint32_t l)
{
    if (KSE(KSE_STATUS) & KSE_STATUS_QFULL) { bad |= 0x10u; return; }
    KSE(KSE_PARAM_ADDR) = SH_PARAM_OFF + l * KSE_LAYER_BYTES;
    KSE(KSE_CMD) = l | (l == 0 ? KSE_CMD_IN_EN : 0u) | (l == KSE_LAYERS - 1u ? KSE_CMD_OUT_EN : 0u);
    issued = l + 1u;
}

void trap_handler(void)
{
    uint32_t cause;
    __asm__ volatile ("csrr %0, mcause" : "=r"(cause));
    if (cause != 0x8000000Bu) {          /* only the machine external interrupt is expected */
        SH(SH_FLAG_DONE) = FLAG_DONE_FAIL | 0x1u;
        for (;;) { }
    }
    uint32_t id = PLIC_CLAIM;
    if (id == KSE_IRQ_ID) {
        uint32_t st = KSE(KSE_IRQ_STATUS);
        KSE(KSE_IRQ_STATUS) = st;        /* W1C before completing the claim */
        if (st & 0x2u) bad |= 0x2u;
        uint32_t d = KSE(KSE_DONE_CNT);
        while (seen < d) {
            seen++;
            if (issued < KSE_LAYERS) issue(issued);
        }
    } else {
        bad |= 0x4u;
    }
    PLIC_CLAIM = id;
    irq_cnt++;
}

int main(void)
{
    PLIC_PRIO(KSE_IRQ_ID) = 1u;
    PLIC_ENABLE0 = 1u << KSE_IRQ_ID;
    PLIC_THRESHOLD = 0u;
    if (KSE(KSE_ID) != KSE_ID_VALUE) bad |= 0x8u;
    KSE(KSE_CTRL) = 0x3u;                /* layer-done and error interrupts */
    KSE(KSE_IN_ADDR) = SH_IN_OFF;
    KSE(KSE_OUT_ADDR) = SH_OUT_OFF;
    KSE(KSE_PARAM_LEN) = KSE_LAYER_WORDS;
    __asm__ volatile ("li t0, 0x800; csrs mie, t0" ::: "t0");

    SH(SH_FLAG_START) = FLAG_START_VALUE;  /* the loader starts on this write */
    issue(0);
    issue(1);

    for (;;) {
        __asm__ volatile ("csrci mstatus, 8" ::: "memory");
        if (seen >= KSE_LAYERS || bad) break;
        __asm__ volatile ("wfi" ::: "memory");
        __asm__ volatile ("csrsi mstatus, 8" ::: "memory");
    }
    if (KSE(KSE_ERR) != 0u) bad |= 0x20u;
    if (KSE(KSE_STATUS) & KSE_STATUS_WORK) bad |= 0x40u;
    if (KSE(KSE_DONE_CNT) != KSE_LAYERS) bad |= 0x80u;
    SH(SH_FLAG_DONE) = bad ? (FLAG_DONE_FAIL | bad) : FLAG_DONE_PASS;
    return 0;
}
