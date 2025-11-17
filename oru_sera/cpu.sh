#!/bin/bash

for ((i=0;i<$(nproc);i++)); do sudo cpufreq-set -c $i -r -g performance; done

sudo cpupower idle-set -D 0
