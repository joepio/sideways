#!/bin/sh
# Parse-checks every script; a parse error otherwise makes headless runs hang.
GODOT=${GODOT:-godot}
status=0
for f in $(find . -name "*.gd" -not -path "./addons/*" -not -path "./.godot/*"); do
	out=$($GODOT --headless --path . --check-only --script "res://${f#./}" 2>&1 | grep -E "SCRIPT ERROR|Parse Error" -A1 | grep -v "Identifier not found: GameNight" | grep -B1 "at:" | grep -v "^--")
	if [ -n "$out" ]; then echo "$out"; status=1; fi
done
exit $status
