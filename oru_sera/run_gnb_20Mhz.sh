#!/bin/bash


SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR=$SCRIPT_DIR/..

# Run the GNB
../build/apps/gnb/gnb -c gnb_ru_sera_tdd_n78_20mhz_2x2.yml --metrics.enable_log true
