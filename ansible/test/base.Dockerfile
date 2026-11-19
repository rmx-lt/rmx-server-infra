# Base image of container-test.sh: Ubuntu 24.04 that boots systemd.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq systemd systemd-sysv dbus sudo git curl ca-certificates \
    python3 python3-apt ansible-core iproute2 iptables kmod openssh-server >/dev/null \
 && apt-get clean
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
