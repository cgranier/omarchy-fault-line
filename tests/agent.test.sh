#!/bin/bash
# Tests for bin/faultline-agent with stubbed launchers. Run with: bash tests/agent.test.sh
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
stub=$(mktemp -d)
trap 'rm -rf "$stub"' EXIT
printf '#!/bin/bash\necho claude\n' >"$stub/omarchy-default-agent"
printf '#!/bin/bash\nprintf "%%s\\n" "$@" >"%s/out"\n' "$stub" >"$stub/omarchy-launch-tui"
printf '#!/bin/bash\nexit 0\n' >"$stub/claude"
chmod +x "$stub"/*
passed=0
ok() { passed=$((passed + 1)); echo "ok - $1"; }
brief=$'A systemd user unit is in the failed state: x.service.\n\nRead the log with:\n  journalctl --no-pager -b --user-unit=x.service'
launch() { rm -f "$stub/out"; printf '%s' "$brief" | PATH="$stub:$PATH" bash "$here/bin/faultline-agent" "$@"
  for _ in $(seq 50); do [[ -s $stub/out ]] && return 0; sleep 0.05; done; return 1; }

start=$(date +%s%N); launch; took=$(( ($(date +%s%N) - start) / 1000000 ))
grep -qx -- "--app-id=org.omarchy.agent" "$stub/out"
grep -qx claude "$stub/out"
! grep -qx -- "--permission-mode" "$stub/out"
grep -q "journalctl --no-pager -b --user-unit=x.service" "$stub/out"
ok "default: the agent starts in its ordinary mode with the brief (${took} ms)"

launch --auto-approve
grep -qx -- "--permission-mode" "$stub/out" && grep -qx auto "$stub/out"
ok "--auto-approve restores the bypass flags"

! printf '' | PATH="$stub:$PATH" bash "$here/bin/faultline-agent" 2>/dev/null
ok "an empty brief is refused"
! printf 'x' | PATH="$stub:$PATH" bash "$here/bin/faultline-agent" --yolo 2>/dev/null
! printf 'x' | PATH="$stub:$PATH" bash "$here/bin/faultline-agent" --auto-approve extra 2>/dev/null
ok "unknown or extra arguments are refused"

printf '#!/bin/bash\necho "claude; rm -rf ~"\n' >"$stub/omarchy-default-agent"
! printf 'x' | PATH="$stub:$PATH" bash "$here/bin/faultline-agent" 2>/dev/null
ok "an oddly shaped default agent name is refused"

echo "$passed passed"
