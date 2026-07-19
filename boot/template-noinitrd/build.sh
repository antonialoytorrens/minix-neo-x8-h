#!/bin/sh
# Rebuild the compiled u-boot script images from their text sources.
# Run this after editing aml_autoscript.cmd or s805_autoscript.txt.
set -e
cd "$(dirname "$0")"

mkimage -A arm -O linux -T script -C none -a 0 -e 0 -n "" \
	-d aml_autoscript.cmd aml_autoscript

mkimage -A arm -O linux -T script -C gzip -a 0 -e 0 -n "" \
	-d s805_autoscript.txt s805_autoscript
