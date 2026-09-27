/*
 * Bare-metal firmware: INT8 digits MLP on a VexRiscv + systolic accelerator SoC.
 *
 * 1. GEMM self-test   - random shapes through the accelerator's AXI4 DMA,
 *                       compared word-for-word with a CPU reference.
 * 2. Robustness       - an illegal descriptor must be rejected (ERROR, never
 *                       BUSY) and the next legal job must still be correct.
 * 3. MLP on the SoC   - 360 held-out 8x8 digits, 64-32-10 network. Every
 *                       matrix multiply runs on the accelerator; the CPU does
 *                       the per-channel bias / requantise / ReLU epilogue.
 * 3b. Fused         - same network with bias/requantise/ReLU in hardware
 *                       (per-channel bias vector): no CPU work between layers.
 * 4. MLP on the CPU   - same network, same integer contract, CPU only.
 * 5. Proof            - CRC32 of every hidden activation and logit must match
 *                       the Python golden model bit for bit.
 *
 * Machine-readable "RESULT key=value" lines are parsed by soc/run_soc_sim.py.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <generated/csr.h>
#include <generated/mem.h>
#include <generated/soc.h>
#include <system.h>

#include "dma_descriptor.h"
#include "model_data.h"

/* ACCEL_BASE comes from generated/mem.h (the SoC bus region named "accel"). */
#define MAX_DIM    64
#define BATCH      64

/* ---- platform hooks for the portable driver in sw/ -------------------- */
static uint32_t mmio_read32(uintptr_t base, uint32_t off) {
    return *(volatile uint32_t *)(base + off);
}
static void mmio_write32(uintptr_t base, uint32_t off, uint32_t v) {
    *(volatile uint32_t *)(base + off) = v;
}
static const accel_device_t accel = { ACCEL_BASE, mmio_read32, mmio_write32 };

static uint32_t cycles(void) {
    timer0_uptime_latch_write(1);
    return (uint32_t)timer0_uptime_cycles_read();
}

/* ---- small helpers ----------------------------------------------------- */
static uint32_t crc32(const void *data, uint32_t len) {
    const uint8_t *p = data;
    uint32_t crc = 0xFFFFFFFFu;
    while (len--) {
        crc ^= *p++;
        for (int i = 0; i < 8; i++)
            crc = (crc >> 1) ^ (0xEDB88320u & -(crc & 1u));
    }
    return ~crc;
}

/* LiteX's trimmed libc has no memcmp. */
static int bytes_differ(const void *x, const void *y, uint32_t len) {
    const uint8_t *a = x, *b = y;
    while (len--)
        if (*a++ != *b++) return 1;
    return 0;
}

static uint32_t lcg_state = 12345u;
static int8_t rnd8(void) {
    lcg_state = lcg_state * 1664525u + 1013904223u;
    return (int8_t)(lcg_state >> 24);
}

/* ---- accelerator job --------------------------------------------------- */
typedef struct {
    uint32_t total_cycles;   /* CPU-observed: program -> DONE              */
    uint32_t active_cycles;  /* PERF_ACTIVE: compute-path busy cycles       */
    uint32_t macs;
} job_stats_t;

static int accel_run(const accel_dma_descriptor_t *d, const int32_t *bias_vec,
                     job_stats_t *st) {
    uint32_t t0 = cycles();
    accel_dma_clear_events(&accel);
    if (bias_vec)
        accel_dma_load_bias(&accel, bias_vec, d->n);
    accel_dma_program(&accel, d);
    accel_dma_start(&accel, 0);
    uint32_t s;
    do {
        s = accel_dma_status(&accel);
    } while ((s & DMA_STATUS_BUSY) || !(s & (DMA_STATUS_DONE | DMA_STATUS_ERROR)));
    /* The DMA wrote C behind the CPU's back: drop stale D-cache lines. */
    flush_cpu_dcache();
    uint32_t t1 = cycles();
    if (st) {
        accel_dma_performance_t p = accel_dma_performance(&accel);
        st->total_cycles += t1 - t0;
        st->active_cycles += p.active_cycles;
        st->macs += (uint32_t)p.mac_count;
    }
    accel_dma_clear_events(&accel);
    return (s & DMA_STATUS_ERROR) ? -1 : 0;
}

/* Raw INT32 GEMM: C = A x B. */
static int accel_gemm(const int8_t *a, const int8_t *b, int32_t *c,
                      uint32_t m, uint32_t n, uint32_t k, uint32_t tile_mn,
                      job_stats_t *st) {
    accel_dma_descriptor_t d = {
        .a_base = (uint32_t)(uintptr_t)a, .b_base = (uint32_t)(uintptr_t)b,
        .c_base = (uint32_t)(uintptr_t)c,
        .m = m, .n = n, .k = k,
        .tile_m = tile_mn, .tile_n = tile_mn, .tile_k = k,
        .post_bias = 0, .post_scale_mult = 1, .post_cfg = 0,
    };
    return accel_run(&d, NULL, st);
}

/* Whole quantised layer in hardware: INT8 out = requant(A x B + bias[j]).
 * The packed-INT8 writeback stores whole 32-bit words, so `out` must have
 * room for ceil(m*n/4)*4 bytes (true for every call below). */
static int accel_layer(const int8_t *a, const int8_t *b, int8_t *out,
                       uint32_t m, uint32_t n, uint32_t k, uint32_t tile_mn,
                       const int32_t *bias, int32_t mult, uint32_t shift, int relu,
                       job_stats_t *st) {
    accel_dma_descriptor_t d = {
        .a_base = (uint32_t)(uintptr_t)a, .b_base = (uint32_t)(uintptr_t)b,
        .c_base = (uint32_t)(uintptr_t)out,
        .m = m, .n = n, .k = k,
        .tile_m = tile_mn, .tile_n = tile_mn, .tile_k = k,
        .post_bias = 0, .post_scale_mult = mult,
        .post_cfg = DMA_POST_OUTPUT_INT8 | DMA_POST_SHIFT(shift) | (relu ? DMA_POST_RELU : 0u),
    };
    return accel_run(&d, bias, st);
}

static void cpu_gemm(const int8_t *a, const int8_t *b, int32_t *c,
                     uint32_t m, uint32_t n, uint32_t k) {
    for (uint32_t i = 0; i < m; i++)
        for (uint32_t j = 0; j < n; j++) {
            int32_t acc = 0;
            for (uint32_t x = 0; x < k; x++)
                acc += (int32_t)a[i * k + x] * (int32_t)b[x * n + j];
            c[i * n + j] = acc;
        }
}

/* Mirror of rtl/ml_postprocess.sv and ml.quantized_mlp.requantize_int32,
 * with a per-output-channel bias. */
static void epilogue(const int32_t *acc, const int32_t *bias, int8_t *out,
                     uint32_t m, uint32_t n, int32_t mult, int shift, int relu) {
    for (uint32_t i = 0; i < m; i++)
        for (uint32_t j = 0; j < n; j++) {
            int64_t y = ((int64_t)acc[i * n + j] + bias[j]) * (int64_t)mult;
            y >>= shift;
            if (relu && y < 0) y = 0;
            if (y > 127) y = 127;
            if (y < -128) y = -128;
            out[i * n + j] = (int8_t)y;
        }
}

static uint8_t argmax10(const int8_t *v) {
    uint8_t best = 0;
    for (uint8_t i = 1; i < N_OUT; i++)
        if (v[i] > v[best]) best = i;   /* first maximum wins, like numpy */
    return best;
}

/* ---- buffers ----------------------------------------------------------- */
static int8_t  ta[MAX_DIM * MAX_DIM] __attribute__((aligned(16)));
static int8_t  tb[MAX_DIM * MAX_DIM] __attribute__((aligned(16)));
static int32_t tc_hw[MAX_DIM * MAX_DIM] __attribute__((aligned(16)));
static int32_t tc_sw[MAX_DIM * MAX_DIM] __attribute__((aligned(16)));

static int32_t acc1[BATCH * N_HID] __attribute__((aligned(16)));
static int32_t acc2[BATCH * N_OUT] __attribute__((aligned(16)));
static int8_t  hidden_hw[N_TEST * N_HID] __attribute__((aligned(16)));
static int8_t  logits_hw[N_TEST * N_OUT] __attribute__((aligned(16)));
static int8_t  hidden_sw[N_TEST * N_HID] __attribute__((aligned(16)));
static int8_t  hidden_fx[N_TEST * N_HID] __attribute__((aligned(16)));
static int8_t  logits_fx[N_TEST * N_OUT + 4] __attribute__((aligned(16)));
static int8_t  logits_sw[N_TEST * N_OUT] __attribute__((aligned(16)));

static int failures;
#define CHECK(cond, ...) do { if (!(cond)) { failures++; printf("FAIL: " __VA_ARGS__); printf("\n"); } } while (0)

/* ---- 1. GEMM self-test ------------------------------------------------- */
static void gemm_selftest(uint32_t array_n) {
    static const uint16_t shapes[][3] = {
        {4, 4, 4}, {1, 1, 1}, {5, 6, 9}, {7, 3, 13}, {16, 12, 33},
        {3, 17, 64}, {64, 64, 64}, {33, 31, 47},
    };
    printf("\n[1] GEMM self-test (random INT8, full range)\n");
    for (unsigned s = 0; s < sizeof(shapes) / sizeof(shapes[0]); s++) {
        uint32_t m = shapes[s][0], n = shapes[s][1], k = shapes[s][2];
        for (uint32_t i = 0; i < m * k; i++) ta[i] = rnd8();
        for (uint32_t i = 0; i < k * n; i++) tb[i] = rnd8();
        memset(tc_hw, 0xA5, sizeof(tc_hw));
        job_stats_t st = {0};
        int err = accel_gemm(ta, tb, tc_hw, m, n, k, array_n, &st);
        uint32_t t0 = cycles();
        cpu_gemm(ta, tb, tc_sw, m, n, k);
        uint32_t cpu_cyc = cycles() - t0;
        int ok = !err && bytes_differ(tc_hw, tc_sw, m * n * 4) == 0;
        CHECK(ok, "GEMM %lux%lux%lu mismatch (err=%d)", (unsigned long)m,
              (unsigned long)n, (unsigned long)k, err);
        printf("    M=%2lu N=%2lu K=%2lu  %s  accel %7lu cyc  cpu %8lu cyc\n",
               (unsigned long)m, (unsigned long)n, (unsigned long)k, ok ? "ok  " : "FAIL",
               (unsigned long)st.total_cycles, (unsigned long)cpu_cyc);
        if (m == 64 && n == 64 && k == 64) {
            printf("RESULT gemm64_accel_cycles=%lu\n", (unsigned long)st.total_cycles);
            printf("RESULT gemm64_accel_active=%lu\n", (unsigned long)st.active_cycles);
            printf("RESULT gemm64_cpu_cycles=%lu\n", (unsigned long)cpu_cyc);
        }
    }
}

/* ---- 2. Robustness: illegal descriptor must not wedge the core --------- */
static void robustness(uint32_t array_n) {
    printf("\n[2] Illegal descriptor handling\n");
    accel_dma_descriptor_t bad = {
        .a_base = (uint32_t)(uintptr_t)ta, .b_base = (uint32_t)(uintptr_t)tb,
        .c_base = (uint32_t)(uintptr_t)tc_hw, .m = 4, .n = 4, .k = 4,
        .tile_m = 3, .tile_n = array_n, .tile_k = 4,
        .post_bias = 0, .post_scale_mult = 1, .post_cfg = 0,
    };
    accel_dma_clear_events(&accel);
    accel_dma_program(&accel, &bad);
    accel_dma_start(&accel, 0);
    uint32_t s = 0;
    int busy_seen = 0;
    for (int i = 0; i < 16; i++) {
        s = accel_dma_status(&accel);
        busy_seen |= (s & DMA_STATUS_BUSY) != 0;
    }
    CHECK((s & DMA_STATUS_ERROR) && !busy_seen, "TILE_M=3 not rejected cleanly (status=%lx)",
          (unsigned long)s);
    accel_dma_clear_events(&accel);
    CHECK((accel_dma_status(&accel) & (DMA_STATUS_ERROR | DMA_STATUS_DONE)) == 0,
          "ERROR/DONE not cleared");
    for (uint32_t i = 0; i < 16; i++) { ta[i] = rnd8(); tb[i] = rnd8(); }
    int err = accel_gemm(ta, tb, tc_hw, 4, 4, 4, array_n, NULL);
    cpu_gemm(ta, tb, tc_sw, 4, 4, 4);
    CHECK(!err && bytes_differ(tc_hw, tc_sw, 64) == 0, "core did not recover after rejected job");
    printf("    TILE_M=3 rejected with ERROR, never BUSY; next job correct: %s\n",
           failures ? "no" : "yes");
}

/* ---- 3/4. The network --------------------------------------------------- */
enum { MODE_CPU = 0, MODE_ACCEL_CPU_EPILOGUE = 1, MODE_ACCEL_FUSED = 2 };

static uint32_t mlp(int use_accel, uint32_t array_n, int8_t *hidden, int8_t *logits,
                    job_stats_t *st, uint32_t *epi_cycles) {
    uint32_t t0 = cycles();
    for (uint32_t base = 0; base < N_TEST; base += BATCH) {
        uint32_t bs = (N_TEST - base) < BATCH ? (N_TEST - base) : BATCH;
        const int8_t *x = &x_test[base * N_IN];
        int8_t *h = &hidden[base * N_HID];
        int8_t *o = &logits[base * N_OUT];
        if (use_accel == MODE_ACCEL_FUSED) {
            /* Hidden INT8 activations go straight back to memory and are the
             * next layer's A operand: no CPU work between the two layers. */
            if (accel_layer(x, w1t, h, bs, N_HID, N_IN, array_n, b1, L1_MULT, L1_SHIFT, 1, st))
                failures++;
            if (accel_layer(h, w2t, o, bs, N_OUT, N_HID, array_n, b2, L2_MULT, L2_SHIFT, 0, st))
                failures++;
            continue;
        }
        if (use_accel) {
            if (accel_gemm(x, w1t, acc1, bs, N_HID, N_IN, array_n, st)) failures++;
        } else {
            cpu_gemm(x, w1t, acc1, bs, N_HID, N_IN);
        }
        uint32_t e0 = cycles();
        epilogue(acc1, b1, h, bs, N_HID, L1_MULT, L1_SHIFT, 1);
        uint32_t e1 = cycles();
        if (use_accel) {
            if (accel_gemm(h, w2t, acc2, bs, N_OUT, N_HID, array_n, st)) failures++;
        } else {
            cpu_gemm(h, w2t, acc2, bs, N_OUT, N_HID);
        }
        uint32_t e2 = cycles();
        epilogue(acc2, b2, o, bs, N_OUT, L2_MULT, L2_SHIFT, 0);
        *epi_cycles += (e1 - e0) + (cycles() - e2);
    }
    return cycles() - t0;
}

static uint32_t score(const int8_t *logits, uint32_t *golden_match) {
    uint32_t correct = 0;
    *golden_match = 0;
    for (uint32_t i = 0; i < N_TEST; i++) {
        uint8_t p = argmax10(&logits[i * N_OUT]);
        correct += p == labels[i];
        *golden_match += p == golden_pred[i];
    }
    return correct;
}

int main(void) {
    uint32_t array_n = ACCEL_ARRAY_N;
    printf("\n=== VexRiscv + %lux%lu INT8 systolic accelerator ===\n",
           (unsigned long)array_n, (unsigned long)array_n);
    printf("RESULT array_n=%lu\n", (unsigned long)array_n);

    gemm_selftest(array_n);
    robustness(array_n);

    printf("\n[3] Digits MLP 64-32-10, %d images, GEMMs on the accelerator\n", N_TEST);
    job_stats_t st = {0};
    uint32_t epi_hw = 0;
    uint32_t hw_cycles = mlp(MODE_ACCEL_CPU_EPILOGUE, array_n, hidden_hw, logits_hw, &st, &epi_hw);

    printf("[3b] Same, with bias/requantise/ReLU fused into the accelerator\n");
    job_stats_t stf = {0};
    uint32_t epi_fx = 0;
    uint32_t fx_cycles = mlp(MODE_ACCEL_FUSED, array_n, hidden_fx, logits_fx, &stf, &epi_fx);

    printf("[4] Same network on the CPU only\n");
    uint32_t epi_sw = 0;
    uint32_t sw_cycles = mlp(MODE_CPU, array_n, hidden_sw, logits_sw, NULL, &epi_sw);

    uint32_t hw_golden, sw_golden;
    uint32_t hw_correct = score(logits_hw, &hw_golden);
    uint32_t sw_correct = score(logits_sw, &sw_golden);
    uint32_t fx_golden;
    uint32_t fx_correct = score(logits_fx, &fx_golden);
    uint32_t fhcrc = crc32(hidden_fx, sizeof(hidden_fx));
    uint32_t flcrc = crc32(logits_fx, N_TEST * N_OUT);
    CHECK(fhcrc == GOLDEN_HIDDEN_CRC && flcrc == GOLDEN_LOGITS_CRC,
          "fused path not bit-exact (hidden %08lx logits %08lx)", (unsigned long)fhcrc,
          (unsigned long)flcrc);
    CHECK(fx_golden == N_TEST, "fused: only %lu/%d predictions match golden",
          (unsigned long)fx_golden, N_TEST);
    uint32_t hcrc = crc32(hidden_hw, sizeof(hidden_hw));
    uint32_t lcrc = crc32(logits_hw, sizeof(logits_hw));

    CHECK(hcrc == GOLDEN_HIDDEN_CRC, "hidden CRC %08lx != golden %08lx",
          (unsigned long)hcrc, (unsigned long)GOLDEN_HIDDEN_CRC);
    CHECK(lcrc == GOLDEN_LOGITS_CRC, "logits CRC %08lx != golden %08lx",
          (unsigned long)lcrc, (unsigned long)GOLDEN_LOGITS_CRC);
    CHECK(bytes_differ(hidden_hw, hidden_sw, sizeof(hidden_hw)) == 0, "HW/CPU hidden differ");
    CHECK(bytes_differ(logits_hw, logits_sw, sizeof(logits_hw)) == 0, "HW/CPU logits differ");
    CHECK(hw_golden == N_TEST, "only %lu/%d predictions match golden", (unsigned long)hw_golden, N_TEST);
    CHECK(hw_correct == GOLDEN_CORRECT, "accuracy %lu != golden %d", (unsigned long)hw_correct,
          GOLDEN_CORRECT);

    uint32_t total_macs = N_TEST * (N_IN * N_HID + N_HID * N_OUT);
    printf("\n[5] Results\n");
    printf("    accuracy (accelerator)   : %lu/%d\n", (unsigned long)hw_correct, N_TEST);
    printf("    accuracy (fused accel)   : %lu/%d\n", (unsigned long)fx_correct, N_TEST);
    printf("    accuracy (CPU only)      : %lu/%d\n", (unsigned long)sw_correct, N_TEST);
    printf("    bit-exact vs Python      : hidden crc %08lx, logits crc %08lx -> %s\n",
           (unsigned long)hcrc, (unsigned long)lcrc,
           (hcrc == GOLDEN_HIDDEN_CRC && lcrc == GOLDEN_LOGITS_CRC) ? "MATCH" : "MISMATCH");
    printf("    end-to-end cycles, accel : %lu  (GEMM jobs %lu, compute-active %lu, epilogue %lu)\n",
           (unsigned long)hw_cycles, (unsigned long)st.total_cycles,
           (unsigned long)st.active_cycles, (unsigned long)epi_hw);
    printf("    end-to-end cycles, fused : %lu  (compute-active %lu)\n",
           (unsigned long)fx_cycles, (unsigned long)stf.active_cycles);
    printf("    end-to-end cycles, CPU   : %lu  (epilogue %lu)\n",
           (unsigned long)sw_cycles, (unsigned long)epi_sw);
    printf("    useful MACs              : %lu (accel counted %lu)\n",
           (unsigned long)total_macs, (unsigned long)st.macs);
    printf("    speed-up, whole network  : %lu.%02lux\n",
           (unsigned long)(sw_cycles / hw_cycles),
           (unsigned long)((sw_cycles * 100ull / hw_cycles) % 100));
    printf("    speed-up, fused network  : %lu.%02lux\n",
           (unsigned long)(sw_cycles / fx_cycles),
           (unsigned long)((sw_cycles * 100ull / fx_cycles) % 100));
    printf("    speed-up, GEMM only      : %lu.%02lux\n",
           (unsigned long)((sw_cycles - epi_sw) / st.total_cycles),
           (unsigned long)(((sw_cycles - epi_sw) * 100ull / st.total_cycles) % 100));

    printf("RESULT images=%d\n", N_TEST);
    printf("RESULT accel_correct=%lu\n", (unsigned long)hw_correct);
    printf("RESULT cpu_correct=%lu\n", (unsigned long)sw_correct);
    printf("RESULT golden_correct=%d\n", GOLDEN_CORRECT);
    printf("RESULT hidden_crc=%08lx\n", (unsigned long)hcrc);
    printf("RESULT logits_crc=%08lx\n", (unsigned long)lcrc);
    printf("RESULT mlp_accel_cycles=%lu\n", (unsigned long)hw_cycles);
    printf("RESULT mlp_accel_gemm_cycles=%lu\n", (unsigned long)st.total_cycles);
    printf("RESULT mlp_accel_active_cycles=%lu\n", (unsigned long)st.active_cycles);
    printf("RESULT mlp_accel_epilogue_cycles=%lu\n", (unsigned long)epi_hw);
    printf("RESULT fused_correct=%lu\n", (unsigned long)fx_correct);
    printf("RESULT fused_hidden_crc=%08lx\n", (unsigned long)fhcrc);
    printf("RESULT fused_logits_crc=%08lx\n", (unsigned long)flcrc);
    printf("RESULT mlp_fused_cycles=%lu\n", (unsigned long)fx_cycles);
    printf("RESULT mlp_fused_active_cycles=%lu\n", (unsigned long)stf.active_cycles);
    printf("RESULT mlp_cpu_cycles=%lu\n", (unsigned long)sw_cycles);
    printf("RESULT mlp_cpu_epilogue_cycles=%lu\n", (unsigned long)epi_sw);
    printf("RESULT macs=%lu\n", (unsigned long)total_macs);
    printf("RESULT failures=%d\n", failures);
    printf("\n%s\n", failures ? "SOC TEST FAILED" : "SOC TEST PASSED");

    sim_finish_finish_write(1);
    for (;;) {}
    return 0;
}
