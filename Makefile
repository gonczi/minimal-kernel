# Minimal Linux Kernel Makefile for QEMU-KVM (UEFI Boot)
# Supports: Terminal, Storage, Ethernet
# Uses latest stable kernel

# KERNEL_VERSION := $(shell curl -s https://www.kernel.org/releases.json | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('latest_stable',{}).get('version') or d.get('latest_stable',{}).get('number') or '')")
KERNEL_VERSION := 6.17.8
KERNEL_URL := https://cdn.kernel.org/pub/linux/kernel/v$(shell echo $(KERNEL_VERSION) | cut -d. -f1).x/linux-$(KERNEL_VERSION).tar.xz
KERNEL_ARCHIVE := linux-$(KERNEL_VERSION).tar.xz
KERNEL_DIR := linux-$(KERNEL_VERSION)
BZIMAGE := $(KERNEL_DIR)/arch/x86/boot/bzImage
BUILD_DIR := build
DISK_IMG := $(BUILD_DIR)/disk.img

# Initramfs and GRUB wiring
INITRD_ROOT := $(BUILD_DIR)/initrd-root
INITRAMFS := $(BUILD_DIR)/initramfs.cpio.gz
GRUB_BIN := $(BUILD_DIR)/BOOTX64.EFI
GRUB_CFG := $(BUILD_DIR)/grub.cfg
GRUB_MKSTANDALONE := $(shell command -v grub-mkstandalone || true)

# Busybox source build (rather than relying on host binary)
BUSYBOX_VERSION ?= 1.37.0
BUSYBOX_ARCHIVE := busybox-$(BUSYBOX_VERSION).tar.bz2
BUSYBOX_URL := https://busybox.net/downloads/$(BUSYBOX_ARCHIVE)
BUSYBOX_DIR := busybox-$(BUSYBOX_VERSION)
BUSYBOX_BIN := $(BUSYBOX_DIR)/busybox

# Build resource limits (can be overridden on the make command line)
# Example: make JOBS=4 MEM_LIMIT_MB=4096 run
JOBS ?= $(shell nproc)
# MEM_LIMIT_MB=0 disables the memory ulimit.
MEM_LIMIT_MB ?= 0
# Optional: set a root password for the initramfs. Example: make initramfs ROOT_PASS=root
ROOT_PASS ?= root

.PHONY: all clean distclean run kernel initramfs grub disk busybox

all: $(DISK_IMG)

$(KERNEL_ARCHIVE):
	@echo "Downloading Linux kernel version $(KERNEL_VERSION)"
	curl -LO $(KERNEL_URL)

$(KERNEL_DIR): $(KERNEL_ARCHIVE)
	tar xf $(KERNEL_ARCHIVE)

kernel: $(BZIMAGE)

$(BZIMAGE): $(KERNEL_DIR)
	cd $(KERNEL_DIR) && make mrproper
	cd $(KERNEL_DIR) && make defconfig
	cd $(KERNEL_DIR) && scripts/config --disable ALL
	cd $(KERNEL_DIR) && scripts/config --enable CONFIG_VT
	cd $(KERNEL_DIR) && scripts/config --enable CONFIG_VT_CONSOLE
	cd $(KERNEL_DIR) && scripts/config --enable CONFIG_VGA_CONSOLE
	cd $(KERNEL_DIR) && scripts/config --enable CONFIG_DUMMY_CONSOLE
	cd $(KERNEL_DIR) && scripts/config --enable CONFIG_SERIAL_8250
	cd $(KERNEL_DIR) && scripts/config --enable CONFIG_SERIAL_8250_CONSOLE
	cd $(KERNEL_DIR) && scripts/config --enable CONFIG_BLK_DEV
	cd $(KERNEL_DIR) && scripts/config --enable CONFIG_BLK_DEV_SD
	cd $(KERNEL_DIR) && scripts/config --enable CONFIG_NET
	cd $(KERNEL_DIR) && scripts/config --enable CONFIG_NETDEVICES
	cd $(KERNEL_DIR) && scripts/config --enable CONFIG_E1000
	cd $(KERNEL_DIR) && scripts/config --enable CONFIG_DEVTMPFS
	cd $(KERNEL_DIR) && scripts/config --enable CONFIG_DEVTMPFS_MOUNT
	@echo "Building kernel with JOBS=$(JOBS) MEM_LIMIT_MB=$(MEM_LIMIT_MB)"
	cd $(KERNEL_DIR) && \
	if [ "$(MEM_LIMIT_MB)" -gt "0" ]; then \
		ulimit -v $$(($(MEM_LIMIT_MB) * 1024)); \
		echo "Applied virtual memory limit: $$(($(MEM_LIMIT_MB) * 1024)) KB"; \
	fi && \
	make -j$(JOBS)
	


initramfs: $(INITRAMFS)

busybox: $(BUSYBOX_BIN)

$(BUSYBOX_ARCHIVE):
	@echo "Downloading busybox $(BUSYBOX_VERSION)"
	curl -LO $(BUSYBOX_URL)

$(BUSYBOX_DIR): $(BUSYBOX_ARCHIVE)
	tar xf $(BUSYBOX_ARCHIVE)

# Build a static busybox with required applets (cttyhack, networking, shell)
$(BUSYBOX_BIN): $(BUSYBOX_DIR) busybox-minimal.config
	@echo "Applying minimal busybox static config"
	cp busybox-minimal.config $(BUSYBOX_DIR)/.config
	cd $(BUSYBOX_DIR) && yes "" | make oldconfig >/dev/null
	@echo "Building busybox (minimal static)"
	cd $(BUSYBOX_DIR) && make -j$(JOBS)
	@echo "Built busybox: $(BUSYBOX_BIN)"

# Build a tiny initramfs using locally built busybox (static), not host busybox.
$(INITRAMFS): $(BUSYBOX_BIN) init
	@echo "Building initramfs using locally built busybox $(BUSYBOX_BIN)"
	rm -rf $(INITRD_ROOT)
	mkdir -p $(INITRD_ROOT)/bin $(INITRD_ROOT)/sbin $(INITRD_ROOT)/proc \
		$(INITRD_ROOT)/sys $(INITRD_ROOT)/dev $(INITRD_ROOT)/usr/bin \
		$(INITRD_ROOT)/usr/sbin $(INITRD_ROOT)/etc

	cp $(BUSYBOX_BIN) $(INITRD_ROOT)/bin/busybox
	chmod +x $(INITRD_ROOT)/bin/busybox

	# Create common symlinks (avoid reliance on busybox --install for minimal deterministic set)
	for a in sh mount mknod hostname ip ifconfig cttyhack clear getty; do \
		ln -sf busybox $(INITRD_ROOT)/bin/$$a; \
	done

	# Copy external init script
	cp $(CURDIR)/init $(INITRD_ROOT)/init
	chmod +x $(INITRD_ROOT)/init

	# Copy hello script if present
	@if [ -f $(CURDIR)/hello.sh ]; then \
		cp $(CURDIR)/hello.sh $(INITRD_ROOT)/hello.sh; \
		chmod +x $(INITRD_ROOT)/hello.sh; \
		echo "[initramfs] Added hello.sh"; \
	fi

	# Optional root password
	@if [ -n "$(ROOT_PASS)" ]; then \
		mkdir -p $(INITRD_ROOT)/etc; \
		echo "root:x:0:0:root:/root:/bin/sh" > $(INITRD_ROOT)/etc/passwd; \
		HASH=$$(openssl passwd -6 '$(ROOT_PASS)'); \
		if [ -z "$$HASH" ]; then echo "Failed to generate password hash"; exit 1; fi; \
		echo "root:$${HASH}:18518:0:99999:7:::" > $(INITRD_ROOT)/etc/shadow; \
		chmod 600 $(INITRD_ROOT)/etc/shadow; \
	fi

	# Produce compressed cpio
	cd $(INITRD_ROOT) && find . | cpio -H newc -o | gzip -9 > ../initramfs.cpio.gz
	@echo "Created $(INITRAMFS)"

grub: $(GRUB_BIN)

# Create a standalone GRUB EFI containing an embedded grub.cfg using grub-mkstandalone
$(GRUB_BIN): $(GRUB_CFG)
	@if [ -z "$(GRUB_MKSTANDALONE)" ]; then \
		echo "grub-mkstandalone not found. Install grub2-common or grub-efi-amd64-bin."; \
		echo "Debian/Ubuntu: sudo apt install grub-mkstandalone grub-efi-amd64-bin"; \
		exit 1; \
	fi
	@echo "Building GRUB standalone EFI with embedded config"
	$(GRUB_MKSTANDALONE) -O x86_64-efi -o $(GRUB_BIN) \
		--modules="part_gpt fat search search_label linux" \
		"boot/grub/grub.cfg=$(GRUB_CFG)"
	@echo "Created GRUB EFI: $(GRUB_BIN)"

# minimal grub.cfg

$(GRUB_CFG):
	@echo "Installing GRUB config from ${CURDIR}/grub.cfg";
	@mkdir -p $(dir $(GRUB_CFG)); \
	cp $(CURDIR)/grub.cfg $(GRUB_CFG);


disk: $(DISK_IMG)

# ESP starts at sector 2048 (1 MB offset) inside the GPT image
ESP_OFFSET := 1048576
ESP_IMG := $(DISK_IMG)@@$(ESP_OFFSET)

$(DISK_IMG): $(GRUB_BIN) $(INITRAMFS) $(BZIMAGE)
	@echo "Creating GPT disk image with EFI System Partition"
	rm -f $(DISK_IMG)
	dd if=/dev/zero of=$(DISK_IMG) bs=1M count=64
	sgdisk --clear --new=1:2048:131038 --typecode=1:ef00 --change-name=1:EFI $(DISK_IMG)
	mformat -i $(ESP_IMG) -F -T 128991 -v EFI ::
	mmd -i $(ESP_IMG) ::/EFI
	mmd -i $(ESP_IMG) ::/EFI/BOOT
	mcopy -i $(ESP_IMG) $(GRUB_BIN) ::/EFI/BOOT/BOOTX64.EFI
	mcopy -i $(ESP_IMG) $(BZIMAGE) ::/vmlinuz
	mcopy -i $(ESP_IMG) $(INITRAMFS) ::/initramfs.cpio.gz

run:
	qemu-system-x86_64 \
	-enable-kvm \
	-m 1G \
	-smp 2 \
	-drive file=$(DISK_IMG),format=raw \
	-netdev user,id=net0,net=192.168.0.0/24,dhcpstart=192.168.0.9  \
	-device e1000,netdev=net0 \
	-serial mon:stdio \
	-vga none \
	-display none \
	-bios /usr/share/ovmf/OVMF.fd

clean:
	@echo "Cleaning build artifacts (preserving downloaded archives)"
	@rm -rf $(KERNEL_DIR) $(BUSYBOX_DIR) $(BUILD_DIR)
	@echo "To also remove downloaded archives, run: make distclean"

distclean: clean
	@echo "Removing downloaded archives: $(KERNEL_ARCHIVE) $(BUSYBOX_ARCHIVE)"
	@rm -f $(KERNEL_ARCHIVE) $(BUSYBOX_ARCHIVE)
