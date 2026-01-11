FROM debian:sid

RUN apt-get update && \
    apt-get install -y debootstrap gdisk e2fsprogs dosfstools erofs-utils udev bubblewrap util-linux && \
    rm -rf /var/cache/apt/*

COPY data /data
COPY jugendhackt-iso.sh /jugendhackt-iso.sh

CMD ["/jugendhackt-iso.sh"]
