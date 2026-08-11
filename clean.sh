#!/usr/bin/env bash

sudo killall -9 pipeline_nids 2>/dev/null || true
sudo rm -rf /var/run/dpdk/rte/
sudo find csv_results/ -name "*.log" -type f -delete