#!/bin/sh
# Delayed ring allocation after package install/upgrade.
# Args: <delay_seconds>
delay="${1:-10}"
pidfile=/var/run/babel-monitor-defer-ring.pid
flag=/tmp/babel-monitor-defer-ring

echo $$ > "$pidfile"
sleep "$delay"
rm -f "$pidfile"

# Clear defer flag so the next start allocates UCI ring_size
rm -f "$flag"

if [ -x /etc/init.d/babel-monitor ]; then
	/etc/init.d/babel-monitor restart >/tmp/babel-monitor-defer-ring.log 2>&1 || true
fi
date >>/tmp/babel-monitor-defer-ring.log
echo "babel-monitor deferred ring apply done" >>/tmp/babel-monitor-defer-ring.log
logger -t babel-monitor "deferred ring allocation applied (restart)"
exit 0
