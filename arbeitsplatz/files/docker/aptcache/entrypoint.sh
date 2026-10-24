#!/bin/sh
# Cache im Volume gehört dem Dienstkonto; apt-cacher-ng läuft im Vordergrund ohne root
set -eu
mkdir -p /var/cache/apt-cacher-ng /var/log/apt-cacher-ng /run/apt-cacher-ng
chown -R apt-cacher-ng:apt-cacher-ng /var/cache/apt-cacher-ng /var/log/apt-cacher-ng /run/apt-cacher-ng
exec runuser -u apt-cacher-ng -- /usr/sbin/apt-cacher-ng -c /etc/apt-cacher-ng ForeGround=1
