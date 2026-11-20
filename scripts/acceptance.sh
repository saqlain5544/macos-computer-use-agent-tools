#!/bin/bash
# Acceptance sweep for Quiet Driver.
#
# Drives a real app through the real daemon and checks the promises:
# background driving works, the pointer and focus are untouched, the binding
# survives a relaunch, and a second agent is refused.
#
# Requires: a built driver, the three macOS permissions, and Calculator.
# Usage: ./scripts/acceptance.sh [port]

set -uo pipefail

PORT="${1:-$(head -1 ~/.quiet-driver/port 2>/dev/null)}"
if [ -z "$PORT" ]; then
  echo "no driver running: start it with 'open -a \"Quiet Driver\"'" >&2
  exit 2
fi
BASE="http://127.0.0.1:$PORT"
PASS=0
FAIL=0

post() { # post <json> -> body
  curl -s -m 60 -X POST "$BASE/action" -H 'Content-Type: application/json' -d "$1"
}

check() { # check <name> <condition-result>
  if [ "$2" = "True" ] || [ "$2" = "true" ]; then
    printf '  %-44s PASS\n' "$1"; PASS=$((PASS+1))
  else
    printf '  %-44s FAIL\n' "$1"; FAIL=$((FAIL+1))
  fi
}

jqp() { python3 -c "import json,sys;d=json.load(sys.stdin);print($1)" 2>/dev/null; }

echo "Quiet Driver acceptance — port $PORT"
echo

# Start from a clean slate so the sweep can be run repeatedly.
post '{"tool":"unbind"}' > /dev/null 2>&1
post '{"tool":"launch_app","app":"Calculator"}' > /dev/null 2>&1
sleep 1

echo "binding and driving"
post '{"tool":"bind_app","app":"Calculator","agent":"acceptance","takeover":true}' > /tmp/qd_acc_bind.json
check "bind a background app" "$(jqp 'd["ok"]' < /tmp/qd_acc_bind.json)"
post '{"tool":"click_label","label":"7"}' > /tmp/qd_acc_click.json
check "press a control by label" "$(jqp 'd["ok"]' < /tmp/qd_acc_click.json)"
check "no focus change in background" "$(jqp 'not d["focus_changed"]' < /tmp/qd_acc_click.json)"
check "pointer not moved" "$(jqp 'not d["real_pointer_moved"]' < /tmp/qd_acc_click.json)"

# A point beyond the window's own width must be refused.
WIN_W=$(curl -s -m 10 "$BASE/status" | jqp 'int(d["target"]["bounds"]["w"])')
post "{\"tool\":\"click\",\"x\":$((WIN_W + 120)),\"y\":5}" > /tmp/qd_acc_out.json
check "out-of-window point refused" "$(jqp 'not d["ok"]' < /tmp/qd_acc_out.json)"

echo
echo "the person's focus and pointer"
BEFORE_FRONT=$(curl -s -m 10 "$BASE/status" | jqp 'd["frontmost"]')
BEFORE_EVENTS=$(curl -s -m 10 "$BASE/status" | jqp 'd["focus_events"]')
post '{"tool":"click_label","label":"8"}' > /dev/null
post '{"tool":"click_label","label":"9"}' > /dev/null
AFTER_FRONT=$(curl -s -m 10 "$BASE/status" | jqp 'd["frontmost"]')
AFTER_EVENTS=$(curl -s -m 10 "$BASE/status" | jqp 'd["focus_events"]')
check "frontmost app unchanged" "$([ "$BEFORE_FRONT" = "$AFTER_FRONT" ] && echo True || echo False)"
check "driver caused no focus events" "$([ "$BEFORE_EVENTS" = "$AFTER_EVENTS" ] && echo True || echo False)"

echo
echo "artefacts and diagnostics"
post '{"tool":"screenshot","agent":"acceptance"}' > /tmp/qd_acc_shot.json
check "screenshot the bound window" "$(jqp 'd["ok"]' < /tmp/qd_acc_shot.json)"
check "screenshot lands in the agent workspace" "$(jqp 'd["data"]["path"].startswith("/tmp/quiet-driver/agent-acceptance/")' < /tmp/qd_acc_shot.json 2>/dev/null || python3 -c "
import json;d=json.load(open('/tmp/qd_acc_shot.json'));print(d.get('payload',{}).get('path','').startswith('/tmp/quiet-driver/agent-acceptance/'))" 2>/dev/null)"
post '{"tool":"log_friction","problem":"acceptance sweep entry","source_tool":"acceptance"}' > /tmp/qd_acc_fric.json
check "log a friction point" "$(jqp 'd["ok"]' < /tmp/qd_acc_fric.json)"
post '{"tool":"friction_log","limit":5}' > /tmp/qd_acc_log.json
check "read the friction log back" "$(jqp 'd["ok"]' < /tmp/qd_acc_log.json)"

echo
echo "lifecycle and ownership"
post '{"tool":"bind_app","app":"Calculator","agent":"acceptance-2"}' > /tmp/qd_acc_own.json
check "a second agent is refused" "$(jqp 'not d["ok"]' < /tmp/qd_acc_own.json)"
post '{"tool":"bind_app","app":"Calculator","agent":"acceptance-2","takeover":true}' > /tmp/qd_acc_take.json
check "takeover is allowed" "$(jqp 'd["ok"]' < /tmp/qd_acc_take.json)"

post '{"tool":"launch_app","app":"Calculator"}' > /dev/null
sleep 1
post '{"tool":"quit_app","app":"Calculator"}' > /tmp/qd_acc_quit.json
check "quit the app" "$(jqp 'd["ok"]' < /tmp/qd_acc_quit.json)"
sleep 1
post '{"tool":"type_text","text":"x"}' > /tmp/qd_acc_gone.json
check "action on a quit app is refused" "$(jqp 'not d["ok"]' < /tmp/qd_acc_gone.json)"
post '{"tool":"launch_app","app":"Calculator"}' > /tmp/qd_acc_launch.json
check "relaunch in the background" "$(jqp 'd["ok"]' < /tmp/qd_acc_launch.json)"
sleep 1.5
post '{"tool":"click_label","label":"5"}' > /tmp/qd_acc_rebind.json
check "action works after the relaunch" "$(jqp 'd["ok"]' < /tmp/qd_acc_rebind.json)"

echo
echo "files, without a panel or a focus change"
# Documents belong to an app that has them, so drive TextEdit for this part.
post '{"tool":"unbind"}' > /dev/null
post '{"tool":"launch_app","app":"TextEdit"}' > /dev/null
sleep 1
post '{"tool":"bind_app","app":"TextEdit","agent":"acceptance","takeover":true}' > /dev/null
printf 'ACCEPTANCE DOC\n' > /tmp/qd_acc_doc.txt
post '{"tool":"open_file","path":"/tmp/qd_acc_doc.txt"}' > /tmp/qd_acc_open.json
check "open a document in the background" "$(jqp 'd["ok"]' < /tmp/qd_acc_open.json)"
sleep 1
post '{"tool":"documents"}' > /tmp/qd_acc_docs.json
check "list the open documents" "$(jqp 'd["ok"]' < /tmp/qd_acc_docs.json)"
check "the opened document is listed" "$(jqp 'any("qd_acc_doc" in x for x in d["data"]["documents"])' < /tmp/qd_acc_docs.json)"
post '{"tool":"close_file","name":"qd_acc_doc.txt"}' > /tmp/qd_acc_close.json
check "close the document" "$(jqp 'd["ok"]' < /tmp/qd_acc_close.json)"
rm -f /tmp/qd_acc_doc.txt
post '{"tool":"unbind"}' > /dev/null

echo
echo "focused mode, on request"
post '{"tool":"bind_app","app":"Calculator","agent":"acceptance","takeover":true}' > /dev/null
post '{"tool":"set_mode","mode":"focused"}' > /dev/null
post '{"tool":"click_label","label":"6"}' > /tmp/qd_acc_focus.json
check "focused action runs" "$(jqp 'd["ok"]' < /tmp/qd_acc_focus.json)"
check "focus change was reported" "$(jqp 'd["focus_changed"]' < /tmp/qd_acc_focus.json)"
check "focus was restored" "$(jqp 'd["focus_restored"]' < /tmp/qd_acc_focus.json)"
post '{"tool":"set_mode","mode":"background"}' > /dev/null

echo
echo "the MCP surface"
MCP=$(curl -s -m 20 -X POST "$BASE/mcp" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}')
check "MCP lists tools" "$(echo "$MCP" | jqp 'len(d["result"]["tools"]) > 20')"
INIT=$(curl -s -m 20 -X POST "$BASE/mcp" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}')
check "MCP negotiates the protocol" "$(echo "$INIT" | jqp 'd["result"]["protocolVersion"] == "2025-06-18"')"
check "MCP sends instructions" "$(echo "$INIT" | jqp 'len(d["result"]["instructions"]) > 100')"

post '{"tool":"unbind"}' > /dev/null 2>&1

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
