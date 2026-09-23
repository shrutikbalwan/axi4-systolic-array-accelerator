/* Host-side descriptor definitions for dma_descriptor_ctrl. */
#ifndef SYSTOLIC_DMA_DESCRIPTOR_H
#define SYSTOLIC_DMA_DESCRIPTOR_H

#include "accelerator.h"

#define DMA_CTRL          0x0000u
#define DMA_STATUS        0x0004u
#define DMA_A_BASE        0x0008u
#define DMA_B_BASE        0x000Cu
#define DMA_C_BASE        0x0010u
#define DMA_M             0x0014u
#define DMA_N             0x0018u
#define DMA_K             0x001Cu
#define DMA_TILE_M        0x0020u
#define DMA_TILE_N        0x0024u
#define DMA_TILE_K        0x0028u
#define DMA_POST_BIAS     0x002Cu
#define DMA_POST_SCALE    0x0030u
#define DMA_POST_CFG      0x0034u
#define DMA_PERF_ACTIVE   0x0038u
#define DMA_PERF_MAC_LO   0x003Cu
#define DMA_PERF_MAC_HI   0x0040u
#define DMA_PERF_TILES    0x0044u

#define DMA_CTRL_START    (1u << 0)
#define DMA_CTRL_ABORT    (1u << 1)
#define DMA_CTRL_IRQ_EN   (1u << 2)
#define DMA_STATUS_BUSY   (1u << 0)
#define DMA_STATUS_DONE   (1u << 1)
#define DMA_STATUS_ERROR  (1u << 2)
#define DMA_POST_RELU     (1u << 0)
#define DMA_POST_OUTPUT_INT8 (1u << 1)
#define DMA_POST_SHIFT(x) (((uint32_t)(x) & 0x3Fu) << 2)

typedef struct {
    uint32_t a_base;
    uint32_t b_base;
    uint32_t c_base;
    uint32_t m;
    uint32_t n;
    uint32_t k;
    uint32_t tile_m;
    uint32_t tile_n;
    uint32_t tile_k;
    int32_t post_bias;
    int32_t post_scale_mult;
    uint32_t post_cfg;
} accel_dma_descriptor_t;

typedef struct {
    uint32_t active_cycles;
    uint64_t mac_count;
    uint32_t tile_count;
} accel_dma_performance_t;

static inline void accel_dma_program(const accel_device_t *dev,
                                     const accel_dma_descriptor_t *d) {
    accel_write(dev, DMA_A_BASE, d->a_base);
    accel_write(dev, DMA_B_BASE, d->b_base);
    accel_write(dev, DMA_C_BASE, d->c_base);
    accel_write(dev, DMA_M, d->m);
    accel_write(dev, DMA_N, d->n);
    accel_write(dev, DMA_K, d->k);
    accel_write(dev, DMA_TILE_M, d->tile_m);
    accel_write(dev, DMA_TILE_N, d->tile_n);
    accel_write(dev, DMA_TILE_K, d->tile_k);
    accel_write(dev, DMA_POST_BIAS, (uint32_t)d->post_bias);
    accel_write(dev, DMA_POST_SCALE, (uint32_t)d->post_scale_mult);
    accel_write(dev, DMA_POST_CFG, d->post_cfg);
}

static inline void accel_dma_start(const accel_device_t *dev, int irq_enable) {
    accel_write(dev, DMA_CTRL, DMA_CTRL_START |
                (irq_enable ? DMA_CTRL_IRQ_EN : 0u));
}

static inline uint32_t accel_dma_status(const accel_device_t *dev) {
    return accel_read(dev, DMA_STATUS);
}

static inline int accel_dma_busy(const accel_device_t *dev) {
    return (accel_dma_status(dev) & DMA_STATUS_BUSY) != 0u;
}

static inline int accel_dma_done(const accel_device_t *dev) {
    return (accel_dma_status(dev) & DMA_STATUS_DONE) != 0u;
}

static inline int accel_dma_error(const accel_device_t *dev) {
    return (accel_dma_status(dev) & DMA_STATUS_ERROR) != 0u;
}

static inline void accel_dma_clear_events(const accel_device_t *dev) {
    accel_write(dev, DMA_STATUS, DMA_STATUS_DONE | DMA_STATUS_ERROR);
}

static inline void accel_dma_abort(const accel_device_t *dev) {
    accel_write(dev, DMA_CTRL, DMA_CTRL_ABORT);
}

static inline accel_dma_performance_t accel_dma_performance(const accel_device_t *dev) {
    accel_dma_performance_t result;
    result.active_cycles = accel_read(dev, DMA_PERF_ACTIVE);
    result.mac_count = (uint64_t)accel_read(dev, DMA_PERF_MAC_LO) |
                       ((uint64_t)accel_read(dev, DMA_PERF_MAC_HI) << 32);
    result.tile_count = accel_read(dev, DMA_PERF_TILES);
    return result;
}

#endif
