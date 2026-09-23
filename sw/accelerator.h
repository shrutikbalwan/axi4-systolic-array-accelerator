/*
 * Portable MMIO driver contract for the AXI4-Lite accelerator.
 *
 * Platform code supplies accel_mmio_read32/write32. The API is deliberately
 * independent of a particular RISC-V or FPGA vendor so the same register map
 * can be used from bare metal, an RTOS, or a Linux UIO wrapper.
 */
#ifndef SYSTOLIC_ACCELERATOR_H
#define SYSTOLIC_ACCELERATOR_H

#include <stdint.h>

#define ACCEL_CTRL          0x0000u
#define ACCEL_STATUS        0x0004u
#define ACCEL_LEN           0x0008u
#define ACCEL_INFO          0x000Cu
#define ACCEL_CYCLES        0x0010u
#define ACCEL_ACTIVE_CYCLES 0x0020u
#define ACCEL_MAC_COUNT_LO  0x0024u
#define ACCEL_MAC_COUNT_HI  0x0028u
#define ACCEL_A_BASE        0x1000u
#define ACCEL_B_BASE        0x2000u
#define ACCEL_C_BASE        0x3000u

#define ACCEL_CTRL_START    (1u << 0)
#define ACCEL_CTRL_CLR_ACC  (1u << 1)
#define ACCEL_CTRL_SOFT_RST (1u << 2)
#define ACCEL_CTRL_IRQ_EN   (1u << 3)
#define ACCEL_STATUS_BUSY   (1u << 0)
#define ACCEL_STATUS_DONE   (1u << 1)
#define ACCEL_STATUS_ERR    (1u << 2)

typedef uint32_t (*accel_mmio_read32_fn)(uintptr_t base, uint32_t offset);
typedef void (*accel_mmio_write32_fn)(uintptr_t base, uint32_t offset, uint32_t value);

typedef struct {
    uintptr_t base;
    accel_mmio_read32_fn read32;
    accel_mmio_write32_fn write32;
} accel_device_t;

static inline uint32_t accel_read(const accel_device_t *dev, uint32_t offset) {
    return dev->read32(dev->base, offset);
}

static inline void accel_write(const accel_device_t *dev, uint32_t offset, uint32_t value) {
    dev->write32(dev->base, offset, value);
}

static inline void accel_clear_done(const accel_device_t *dev) {
    accel_write(dev, ACCEL_STATUS, ACCEL_STATUS_DONE);
}

static inline uint64_t accel_mac_count(const accel_device_t *dev) {
    uint32_t lo = accel_read(dev, ACCEL_MAC_COUNT_LO);
    uint32_t hi = accel_read(dev, ACCEL_MAC_COUNT_HI);
    return ((uint64_t)hi << 32) | lo;
}

/* Start is separate from wait so an interrupt-driven application can sleep. */
static inline void accel_start(const accel_device_t *dev, uint16_t k, int irq_enable) {
    accel_write(dev, ACCEL_LEN, k);
    accel_write(dev, ACCEL_CTRL, ACCEL_CTRL_START |
                (irq_enable ? ACCEL_CTRL_IRQ_EN : 0u));
}

static inline int accel_done(const accel_device_t *dev) {
    return (accel_read(dev, ACCEL_STATUS) & ACCEL_STATUS_DONE) != 0u;
}

#endif
