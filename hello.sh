#!/bin/sh
# Simple hello world userspace script run by init if present.
# Prints some system info then execs a shell.

set -e
clear 2>/dev/null || true
printf "\n===== Hello from userspace initramfs =====\n"
printf "Kernel: %s\n" "$(uname -sr)"
printf "Date:   %s\n" "$(date)"
printf "CPU:    %s\n" "$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')"
printf "Mem:    %s kB total\n" "$(grep MemTotal /proc/meminfo | awk '{print $2}')"
printf "TTY:    %s\n" "$(tty 2>/dev/null || echo '?')"
printf "=========================================\n\n"

# Drop to interactive shell afterwards
exec sh
