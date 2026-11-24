#!/usr/bin/env bash
# Runs a command and, while it runs, prints one line every SAMPLE_SECONDS
# (default 15) with the host's memory, swap, load and three largest processes.
#
# For the Android emulator jobs: a runner lost to "received a shutdown signal"
# leaves the step's log up to its last flushed line and nothing else, so the
# lines before the loss are the only record of what the host was doing. The
# command's exit status is the script's.
set -o nounset

interval="${SAMPLE_SECONDS:-15}"

sample() {
  while sleep "$interval"; do
    mem="$(free -m | awk 'NR==2 { printf "used=%sM avail=%sM", $3, $7 }')"
    swap="$(free -m | awk 'NR==3 { printf "%sM", $3 }')"
    load="$(cut -d' ' -f1-3 /proc/loadavg)"
    top="$(ps -eo comm=,rss= --sort=-rss | head -n 3 | awk '{ printf "%s:%dM ", $1, $2 / 1024 }')"
    echo "sample $(date -u +%T): mem $mem swap $swap load $load top $top"
  done
}

sample &
sampler=$!
trap 'kill "$sampler" 2>/dev/null || true' EXIT

"$@"
