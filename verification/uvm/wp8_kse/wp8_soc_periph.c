/* WP8 KSSOC-008 validation-only firmware (not production firmware).
 *
 * Real E203 drives every instantiated peripheral of the KSE SoC once:
 *   UART0 (modified apb_uart_sv copy) configuration, register readback,
 *   20-byte TX through GPIOA IOF pad 17 and a 4-byte RX loopback on pad 16;
 *   UART1/UART2, GPIOA/GPIOB, QSPI0, PWM, SPI1/SPI2, I2C0/I2C1, HCLKGEN,
 *   AON, example AXI slave, KSE MMIO, CLINT and PLIC register checks.
 * Every check is recorded as an (id, observed) pair in a shared-SRAM mailbox;
 * the testbench compares the pairs against its own table and monitors the
 * buses.  The CPU also self-checks and writes a final status word.
 * Register offsets/reset values come from the upstream hbirdv2 RTL.
 */
#include <stdint.h>

#define REG32(a) (*(volatile uint32_t *)(uintptr_t)(a))

/* shared-SRAM mailbox (window offset 0x7E000, below the production flags) */
#define MB_BASE    0x4007E000u
#define MB_STATUS  REG32(MB_BASE + 0x0u)
#define MB_PHASE   REG32(MB_BASE + 0x4u)
#define MB_COUNT   REG32(MB_BASE + 0x8u)
#define MB_REC(i)  REG32(MB_BASE + 0x100u + 4u * (uint32_t)(i))

#define PHASE_BOOT     0x57500000u
#define PHASE_RX_READY 0x57520001u
#define STATUS_PASS    0x600D0000u
#define STATUS_FAIL    0xBAD00000u

/* PPI (e203_subsys_perips sirv_icb1to16_bus) */
#define AON_BASE     0x10000000u
#define HCLKGEN_BASE 0x10008000u
#define GPIOA_BASE   0x10012000u
#define UART0_BASE   0x10013000u
#define QSPI0_BASE   0x10014000u
#define PWM_BASE     0x10015000u
#define UART1_BASE   0x10023000u
#define SPI1_BASE    0x10024000u
#define I2C0_BASE    0x10025000u
#define UART2_BASE   0x10033000u
#define SPI2_BASE    0x10034000u
#define I2C1_BASE    0x10035000u
#define GPIOB_BASE   0x10040000u
#define EXPL_BASE    0x10041000u
#define KSE_BASE     0x11000000u
#define CLINT_BASE   0x02000000u
#define PLIC_BASE    0x0C000000u

/* apb_uart_sv: register_adr = PADDR[4:2] */
#define U_RBR 0x00u
#define U_THR 0x00u
#define U_DLL 0x00u
#define U_IER 0x04u
#define U_DLM 0x04u
#define U_FCR 0x08u
#define U_LCR 0x0Cu
#define U_LSR 0x14u
/* apb_gpio */
#define G_PADDIR   0x00u
#define G_PADIN    0x04u
#define G_PADOUT   0x08u
#define G_INTTYPE0 0x10u
#define G_IOFCFG   0x1Cu

#define UART0_DIV  15u            /* bit period = DIV+1 hfclk cycles */
#define POLL_LIMIT 20000u
/* First LSR read after reset.  The upstream GPIO input synchroniser resets to
 * 0 while the RX pad idles high, so every UART sees a falling RX edge at reset
 * release and receives one spurious byte (LSR.DR=1).  Observed behaviour of the
 * unmodified e203_subsys_perips/apb_gpio path, reported as a finding. */
#define LSR_BOOT   0x61u

static volatile uint32_t nrec;
static volatile uint32_t nbad;
static volatile uint32_t first_bad;

static void rec(uint32_t id, uint32_t got, uint32_t exp)
{
    MB_REC(2u * nrec) = id;
    MB_REC(2u * nrec + 1u) = got;
    nrec = nrec + 1u;
    if (got != exp) {
        if (nbad == 0u)
            first_bad = id;
        nbad = nbad + 1u;
    }
}

void trap_handler(void)
{
    uint32_t cause, epc;
    __asm__ volatile ("csrr %0, mcause" : "=r"(cause));
    __asm__ volatile ("csrr %0, mepc" : "=r"(epc));
    MB_REC(500) = cause;
    MB_REC(501) = epc;
    MB_STATUS = STATUS_FAIL | 0xFFFFu;
    for (;;)
        __asm__ volatile ("wfi");
}

static uint32_t wait_lsr(uint32_t base, uint32_t mask, uint32_t value)
{
    uint32_t v = 0u;
    for (uint32_t i = 0; i < POLL_LIMIT; i++) {
        v = REG32(base + U_LSR);
        if ((v & mask) == value)
            return v;
    }
    return v | 0x80000000u;   /* marks an exhausted poll */
}

static const uint8_t message[20] = {
    'K', 'S', 'S', 'O', 'C', '-', '0', '0', '8', ' ',
    'U', 'A', 'R', 'T', '0', ' ', 'O', 'K', '\r', '\n'
};

static void uart_regs(uint32_t base, uint32_t id, uint32_t dll, uint32_t dlm,
                      uint32_t lcr, uint32_t ier)
{
    rec(id + 0u, REG32(base + U_LSR), LSR_BOOT);
    REG32(base + U_LCR) = 0x80u | lcr;
    REG32(base + U_DLL) = dll;
    REG32(base + U_DLM) = dlm;
    rec(id + 1u, REG32(base + U_DLL), dll);
    rec(id + 2u, REG32(base + U_DLM), dlm);
    REG32(base + U_LCR) = lcr;
    rec(id + 3u, REG32(base + U_LCR), lcr);
    REG32(base + U_IER) = ier;
    rec(id + 4u, REG32(base + U_IER), ier);
}

int main(void)
{
    MB_PHASE = PHASE_BOOT;

    /* ---- UART0: reset values, divisor latch, LCR, IER ---- */
    rec(1, REG32(UART0_BASE + U_LSR), LSR_BOOT);
    rec(2, REG32(UART0_BASE + U_LCR), 0x00u);
    rec(3, REG32(UART0_BASE + U_IER), 0x00u);
    REG32(UART0_BASE + U_LCR) = 0x83u;            /* DLAB, 8N1 */
    REG32(UART0_BASE + U_DLL) = UART0_DIV;
    REG32(UART0_BASE + U_DLM) = 0u;
    rec(5, REG32(UART0_BASE + U_DLL), UART0_DIV);
    rec(6, REG32(UART0_BASE + U_DLM), 0u);
    rec(7, REG32(UART0_BASE + U_LCR), 0x83u);
    REG32(UART0_BASE + U_LCR) = 0x03u;
    rec(8, REG32(UART0_BASE + U_LCR), 0x03u);
    REG32(UART0_BASE + U_IER) = 0x05u;
    rec(9, REG32(UART0_BASE + U_IER), 0x05u);
    REG32(UART0_BASE + U_IER) = 0x00u;
    rec(10, REG32(UART0_BASE + U_IER), 0x00u);
    REG32(UART0_BASE + U_FCR) = 0x06u;            /* clear RX/TX FIFOs */
    rec(59, REG32(UART0_BASE + U_LSR), 0x60u);    /* spurious boot byte flushed */

    /* ---- GPIOA: idle-high pad 17, then hand pads 16/17 to UART0 IOF ---- */
    REG32(GPIOA_BASE + G_PADOUT) = 1u << 17;
    rec(11, REG32(GPIOA_BASE + G_PADOUT), 1u << 17);
    REG32(GPIOA_BASE + G_PADDIR) = 1u << 17;
    rec(12, REG32(GPIOA_BASE + G_PADDIR), 1u << 17);
    REG32(GPIOA_BASE + G_IOFCFG) = 3u << 16;
    rec(13, REG32(GPIOA_BASE + G_IOFCFG), 3u << 16);
    rec(14, REG32(GPIOA_BASE + G_PADIN), (1u << 16) | (1u << 18));

    /* ---- UART0 TX: 16-byte burst fills the FIFO, then 4 more ---- */
    uint32_t pos = 0u;
    while (pos < sizeof(message)) {
        if (wait_lsr(UART0_BASE, 0x20u, 0x20u) & 0x80000000u)
            break;
        uint32_t end = pos + 16u;
        if (end > sizeof(message))
            end = sizeof(message);
        for (; pos < end; pos++)
            REG32(UART0_BASE + U_THR) = message[pos];
    }
    rec(4, pos, sizeof(message));
    rec(15, wait_lsr(UART0_BASE, 0x61u, 0x60u), 0x60u);

    /* ---- UART0 RX loopback: testbench drives pad 16 after this phase ---- */
    static const uint8_t rx_expect[4] = {0xA5u, 0x3Cu, 0x00u, 0xFFu};
    MB_PHASE = PHASE_RX_READY;
    for (uint32_t i = 0; i < 4u; i++) {
        uint32_t got = 0xFFFFFFFFu;
        if (!(wait_lsr(UART0_BASE, 0x01u, 0x01u) & 0x80000000u))
            got = REG32(UART0_BASE + U_RBR);
        rec(16u + i, got, rx_expect[i]);
    }
    rec(20, REG32(UART0_BASE + U_LSR), 0x60u);

    /* ---- UART1 / UART2: same module, unconnected-pad instances ---- */
    uart_regs(UART1_BASE, 21, 0x5Au, 0x01u, 0x07u, 0x02u);
    uart_regs(UART2_BASE, 26, 0xC3u, 0x7Eu, 0x1Bu, 0x04u);

    /* ---- GPIOB: pad inputs driven by the testbench, INTTYPE0 R/W ---- */
    rec(31, REG32(GPIOB_BASE + G_PADIN), 0x5A01C3A5u);
    REG32(GPIOB_BASE + G_INTTYPE0) = 0xA5A55A5Au;
    rec(32, REG32(GPIOB_BASE + G_INTTYPE0), 0xA5A55A5Au);

    /* ---- QSPI0 (sirv_flash_qspi): sckdiv reset 3, R/W, restore ---- */
    rec(33, REG32(QSPI0_BASE + 0x00u), 3u);
    REG32(QSPI0_BASE + 0x00u) = 0xA5u;
    rec(34, REG32(QSPI0_BASE + 0x00u), 0xA5u);
    REG32(QSPI0_BASE + 0x00u) = 3u;
    rec(35, REG32(QSPI0_BASE + 0x00u), 3u);

    /* ---- PWM (apb_adv_timer): TIM0_TH and TIM0_CH0_TH ---- */
    REG32(PWM_BASE + 0x008u) = 0x00FF0010u;
    rec(36, REG32(PWM_BASE + 0x008u), 0x00FF0010u);
    REG32(PWM_BASE + 0x00Cu) = 0x00031234u;
    rec(37, REG32(PWM_BASE + 0x00Cu), 0x00031234u);

    /* ---- SPI1 / SPI2 (apb_spi_master): SPIADR, SPICMD, CLKDIV reset ---- */
    REG32(SPI1_BASE + 0x0Cu) = 0x12345678u;
    rec(38, REG32(SPI1_BASE + 0x0Cu), 0x12345678u);
    REG32(SPI1_BASE + 0x08u) = 0xCAFEF00Du;
    rec(39, REG32(SPI1_BASE + 0x08u), 0xCAFEF00Du);
    rec(40, REG32(SPI1_BASE + 0x04u), 0u);
    REG32(SPI2_BASE + 0x0Cu) = 0x87654321u;
    rec(41, REG32(SPI2_BASE + 0x0Cu), 0x87654321u);
    REG32(SPI2_BASE + 0x08u) = 0x0BADF00Du;
    rec(42, REG32(SPI2_BASE + 0x08u), 0x0BADF00Du);

    /* ---- I2C0 / I2C1 (apb_i2c, core disabled): STATUS, PRESCALER, TX ---- */
    rec(43, REG32(I2C0_BASE + 0x0Cu), 0u);
    REG32(I2C0_BASE + 0x00u) = 0xBEEFu;
    rec(44, REG32(I2C0_BASE + 0x00u), 0xBEEFu);
    REG32(I2C0_BASE + 0x10u) = 0x5Au;
    rec(45, REG32(I2C0_BASE + 0x10u), 0x5Au);
    REG32(I2C1_BASE + 0x00u) = 0x1234u;
    rec(46, REG32(I2C1_BASE + 0x00u), 0x1234u);
    REG32(I2C1_BASE + 0x10u) = 0xA5u;
    rec(47, REG32(I2C1_BASE + 0x10u), 0xA5u);
    rec(48, REG32(I2C1_BASE + 0x0Cu), 0u);

    /* ---- HCLKGEN (sirv_hclkgen_regs): reset values only ---- */
    rec(49, REG32(HCLKGEN_BASE + 0x04u), 0x40000000u);
    rec(50, REG32(HCLKGEN_BASE + 0x08u), 0x00044642u);
    rec(51, REG32(HCLKGEN_BASE + 0x0Cu), 0x00000100u);

    /* ---- AON (sirv_aon, lfclk domain via CDC): backup register 0 ---- */
    REG32(AON_BASE + 0x080u) = 0xC0FFEE01u;
    rec(52, REG32(AON_BASE + 0x080u), 0xC0FFEE01u);

    /* ---- Example AXI slave: write accepted, read returns zero ---- */
    REG32(EXPL_BASE + 0x0u) = 0xDEADBEEFu;
    rec(53, REG32(EXPL_BASE + 0x0u), 0u);

    /* ---- KSE MMIO on PPI O12 ---- */
    rec(54, REG32(KSE_BASE + 0x000u), 0x4B534531u);

    /* ---- CLINT mtimecmp low word ---- */
    rec(55, REG32(CLINT_BASE + 0x4000u), 0xFFFFFFFFu);
    REG32(CLINT_BASE + 0x4000u) = 0x89ABCDEFu;
    rec(56, REG32(CLINT_BASE + 0x4000u), 0x89ABCDEFu);
    REG32(CLINT_BASE + 0x4000u) = 0xFFFFFFFFu;

    /* ---- PLIC priority of source 3 (UART0 irq) ---- */
    REG32(PLIC_BASE + 0x00Cu) = 5u;
    rec(57, REG32(PLIC_BASE + 0x00Cu), 5u);
    REG32(PLIC_BASE + 0x00Cu) = 0u;
    rec(58, REG32(PLIC_BASE + 0x00Cu), 0u);

    MB_COUNT = nrec;
    MB_STATUS = nbad ? (STATUS_FAIL | (first_bad << 8) | (nbad & 0xFFu))
                     : (STATUS_PASS | nrec);
    return 0;
}
