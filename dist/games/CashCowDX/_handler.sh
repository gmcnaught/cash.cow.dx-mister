#!/bin/sh
# MiSTer Frontier hook: Master_Daemon runs games/<CORENAME>/_handler.sh when the
# core loads and kills it on core change. Without Frontier, cashcowdx_daemon.sh
# does the same job.
exec /media/fat/games/CashCowDX/launch.sh
