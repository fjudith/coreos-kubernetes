#!/bin/bash
CMD="ip link show && ip addr && ip route && arp -an && bridge fdb show && ip route show table local && sudo iptables-save"
for SERVER in w1 c1; do echo "Server: $SERVER"; vagrant ssh $SERVER -- "${CMD}"; done