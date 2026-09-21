#!/bin/sh
# Shared deferred ring allocation for babel-monitor install/upgrade.
# During apk post-* the GUI is still waiting on apk; allocating a large
# sample ring can OOM low-RAM devices and kill uhttpd before "done".
# Touch a defer flag so monitord starts with ring_size=none capacity,
# then setsid a sleeper that clears the flag and restarts the daemon.

BM_DEFER_FLAG=/tmp/babel-monitor-defer-ring
BM_DEFER_PID=/var/run/babel-monitor-defer-ring.pid
BM_DEFER_HELPER=/usr/share/babel_monitor/defer-ring-apply.sh

bm_cancel_deferred_ring() {
	if [ -f "$BM_DEFER_PID" ]; then
		opid=$(cat "$BM_DEFER_PID" 2>/dev/null)
		[ -n "$opid" ] && kill "$opid" 2>/dev/null || true
		rm -f "$BM_DEFER_PID"
	fi
}

bm_schedule_deferred_ring() {
	delay="${1:-10}"
	touch "$BM_DEFER_FLAG"
	bm_cancel_deferred_ring
	# setsid: detach from apk process group so apk/GUI can finish
	if [ -x "$BM_DEFER_HELPER" ]; then
		setsid "$BM_DEFER_HELPER" "$delay" </dev/null >/dev/null 2>&1 &
	else
		(
			sleep "$delay"
			rm -f "$BM_DEFER_FLAG"
			[ -x /etc/init.d/babel-monitor ] && /etc/init.d/babel-monitor restart >/dev/null 2>&1 || true
		) &
	fi
}
