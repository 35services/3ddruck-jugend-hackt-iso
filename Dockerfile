FROM debian:sid

RUN apt-get update && \
    apt-get install -y debootstrap gdisk e2fsprogs dosfstools erofs-utils udev bubblewrap util-linux parted expect qemu-system-x86 ovmf curl && \
    rm -rf /var/cache/apt/*

RUN usermod -aG kvm root

COPY data /data
COPY jugendhackt-iso.sh /jugendhackt-iso.sh

CMD ["/jugendhackt-iso.sh"]
