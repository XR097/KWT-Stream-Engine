/* Validation-only firmware. Retain the production scheduler/ISR definitions,
 * then exercise CPU SRAM accesses while the real loader and engine run. */
#define main kse_original_main
#include "../../../firmware/kse/main.c"
#undef main

static volatile uint32_t stress_operations;
#ifndef KSE_STRESS_SEED
#define KSE_STRESS_SEED 7u
#endif

int main(void)
{
    PLIC_PRIO(KSE_IRQ_ID) = 1u;
    PLIC_ENABLE0 = 1u << KSE_IRQ_ID;
    PLIC_THRESHOLD = 0u;
    if (KSE(KSE_ID) != KSE_ID_VALUE) bad |= 0x8u;
    KSE(KSE_CTRL) = 3u;
    KSE(KSE_IN_ADDR) = SH_IN_OFF;
    KSE(KSE_OUT_ADDR) = SH_OUT_OFF;
    KSE(KSE_PARAM_LEN) = KSE_LAYER_WORDS;
    __asm__ volatile ("li t0, 0x800; csrs mie, t0" ::: "t0");
    SH(SH_FLAG_START) = FLAG_START_VALUE;
    issue(0);
    issue(1);
    __asm__ volatile ("csrsi mstatus, 8" ::: "memory");
    /* The same recorded seed controls the real CPU address/data stream as
     * well as the UVM loader stalls. Scratch 0x70000..0x73fff is disjoint
     * from image 0..0x4eb3f, output 0x60000..0x618bf, and flags 0x7f000. */
    uint32_t rng = 0x6d258fa1u ^ KSE_STRESS_SEED;
    while (seen < KSE_LAYERS && !bad) {
        rng ^= rng << 13;
        rng ^= rng >> 17;
        rng ^= rng << 5;
        uintptr_t a = SHRAM_BASE + 0x70000u + (rng & 0x3ffcu);
        uint32_t x = rng ^ 0xa5837e19u;
        uint32_t b = ((x >> 24) ^ 0x5au) & 255u;
        uint32_t h = (x ^ 0xbad1u) & 65535u;
        REG32(a) = x;
        ((volatile uint8_t *)a)[1] = (uint8_t)b;
        ((volatile uint16_t *)a)[1] = (uint16_t)h;
        if (REG32(a) != ((x & 255u) | (b << 8) | (h << 16))) bad |= 0x100u;
        stress_operations++;
    }
    __asm__ volatile ("csrci mstatus, 8" ::: "memory");
    if (stress_operations < 32u) bad |= 0x200u;
    if (KSE(KSE_ERR) != 0u) bad |= 0x20u;
    if (KSE(KSE_STATUS) & KSE_STATUS_WORK) bad |= 0x40u;
    if (KSE(KSE_DONE_CNT) != KSE_LAYERS) bad |= 0x80u;
    SH(SH_FLAG_DONE) = bad ? (FLAG_DONE_FAIL | bad) : FLAG_DONE_PASS;
    return 0;
}
