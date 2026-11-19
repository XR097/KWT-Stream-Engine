# KSE SoC firmware.  Outputs go to $(BUILD) (outside the repository by default).
#   make -C firmware/kse [BUILD=dir] [RISCV=prefix]
RISCV_PREFIX ?= riscv-none-elf-
RISCV ?= $(RISCV_PREFIX)
BUILD ?= $(CURDIR)/../../run/fw
CC      := $(RISCV)gcc
OBJCOPY := $(RISCV)objcopy
OBJDUMP := $(RISCV)objdump
ARCH    := -march=rv32imac_zicsr -mabi=ilp32
CFLAGS  := $(ARCH) -O2 -g -Wall -Wextra -Werror -std=c11 -ffreestanding -fno-builtin \
           -fno-common -msmall-data-limit=0 -mno-relax
LDFLAGS := $(ARCH) -nostdlib -nostartfiles -static -Wl,-T,link.ld,--no-relax,--build-id=none
PY      ?= python3

.PHONY: all clean
all: $(BUILD)/kse_fw.itcm.hex $(BUILD)/kse_fw.lst

$(BUILD)/kse_fw.elf: start.S main.c kse_soc.h link.ld
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(LDFLAGS) -Wl,-Map,$(BUILD)/kse_fw.map start.S main.c -o $@

$(BUILD)/kse_fw.bin: $(BUILD)/kse_fw.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD)/kse_fw.lst: $(BUILD)/kse_fw.elf
	$(OBJDUMP) -d -S $< > $@

$(BUILD)/kse_fw.itcm.hex: $(BUILD)/kse_fw.bin
	$(PY) ../../tools/kse_soc/bin2itcm.py $< $@

clean:
	rm -rf $(BUILD)
