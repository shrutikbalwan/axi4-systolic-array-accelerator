#include "accelerator.h"
#include "dma_descriptor.h"

static uint32_t read32(uintptr_t base, uint32_t offset) {
    (void)base;
    (void)offset;
    return 0;
}

static void write32(uintptr_t base, uint32_t offset, uint32_t value) {
    (void)base;
    (void)offset;
    (void)value;
}

int main(void) {
    accel_device_t dev = {0, read32, write32};
    accel_dma_descriptor_t desc = {
        .a_base = 0x10000000u, .b_base = 0x11000000u, .c_base = 0x12000000u,
        .m = 32, .n = 32, .k = 64, .tile_m = 4, .tile_n = 4, .tile_k = 16,
    };
    accel_dma_program(&dev, &desc);
    accel_dma_start(&dev, 1);
    return accel_dma_busy(&dev) || accel_dma_done(&dev) || accel_dma_error(&dev);
}
