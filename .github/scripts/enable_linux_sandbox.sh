#!/usr/bin/env bash
# Enables and verifies unprivileged user namespaces so Bazel's linux-sandbox
# works. Run before any Bazel server starts: Bazel caches the result.
set -euo pipefail
if [ -f /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]; then
  sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
fi
if [ -f /proc/sys/kernel/unprivileged_userns_clone ] && [ "$(cat /proc/sys/kernel/unprivileged_userns_clone)" = 0 ]; then
  sudo sysctl -w kernel.unprivileged_userns_clone=1
fi
unshare -U -r -m -p -f --mount-proc true
probe="${RUNNER_TEMP:-/tmp}/userns_probe"
trap 'rm -f "$probe"' EXIT
cp /usr/bin/unshare "$probe"
chmod +x "$probe"
"$probe" -U -r -m -p -f --mount-proc true
