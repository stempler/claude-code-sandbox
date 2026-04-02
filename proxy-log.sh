#!/bin/bash
# proxy-log — view Squid proxy traffic logs from inside the sandbox
#
# Usage:
#   proxy-log [all]     Show all proxy requests (default)
#   proxy-log denied    Show only denied requests
#   proxy-log allowed   Show only allowed requests
#   proxy-log follow    Follow log in real time (Ctrl-C to stop)
#   proxy-log help      Show this help

LOG=/var/log/squid/access.log

if [ ! -f "$LOG" ]; then
    echo "Proxy log not found at $LOG (is the firewall initialized?)" >&2
    exit 1
fi

case "${1:-all}" in
    all)
        cat "$LOG"
        ;;
    denied)
        grep "TCP_DENIED" "$LOG"
        ;;
    allowed)
        grep -v "TCP_DENIED" "$LOG"
        ;;
    follow)
        tail -f "$LOG"
        ;;
    help|--help|-h)
        sed -n '2,8p' "$0" | sed 's/^# \?//'
        ;;
    *)
        echo "Unknown subcommand: $1" >&2
        echo "Usage: proxy-log [all|denied|allowed|follow|help]" >&2
        exit 1
        ;;
esac
