# Bare-metal firmware for the VexRiscv + systolic accelerator SoC.
# Invoked by soc/accel_soc.py:  make BUILD_DIR=<litex build dir> OUT=<obj dir>
BUILD_DIR ?= ../../build/soc/n4
OUT       ?= $(BUILD_DIR)/firmware
SRC_DIR   := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

include $(BUILD_DIR)/software/include/generated/variables.mak
include $(SOC_DIRECTORY)/software/common.mak

CFLAGS += -I$(SRC_DIR) -I$(SRC_DIR)/../../sw -O2 -Wall -Wextra -Werror \
          -Wno-missing-prototypes -Wno-unused-parameter -Wno-strict-prototypes \
          -Wno-missing-braces -Wno-sign-compare -Wno-error=unused-function

OBJECTS = $(OUT)/crt0.o $(OUT)/main.o

COMMA = ,
REGULAR_LIBS = $(filter-out $(ALWAYS_LINK_LIBS),$(LIBS))
ALWAYS_LINK_LIBFLAGS = $(if $(ALWAYS_LINK_LIBS),-Wl$(COMMA)--whole-archive $(ALWAYS_LINK_LIBS:lib%=-l%) -Wl$(COMMA)--no-whole-archive)

all: $(OUT)/firmware.bin

$(OUT):
	mkdir -p $(OUT)

$(OUT)/firmware.bin: $(OUT)/firmware.elf
	$(OBJCOPY) -O binary $< $@
	$(TARGET_PREFIX)size $<

$(OUT)/firmware.elf: $(OBJECTS) $(SRC_DIR)linker.ld
	$(CC) $(LDFLAGS) -T $(SRC_DIR)linker.ld -N -o $@ $(OBJECTS) \
		$(PACKAGES:%=-L$(BUILD_DIR)/software/%) \
		-Wl,--start-group $(REGULAR_LIBS:lib%=-l%) $(ALWAYS_LINK_LIBFLAGS) -Wl,--end-group \
		-Wl,--gc-sections -Wl,-Map,$@.map

$(OUT)/main.o: $(SRC_DIR)main.c $(SRC_DIR)model_data.h $(SRC_DIR)../../sw/dma_descriptor.h | $(OUT)
	$(CC) -c $(CFLAGS) $< -o $@

$(OUT)/crt0.o: $(CPU_DIRECTORY)/crt0.S | $(OUT)
	$(CC) -c $(CFLAGS) $< -o $@

clean:
	rm -rf $(OUT)

.PHONY: all clean
