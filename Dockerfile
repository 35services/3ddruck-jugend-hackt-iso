FROM ubuntu:plucky

RUN apt-get update && \
    apt-get install -y debootstrap gdisk parted dosfstools squashfs-tools udev bubblewrap && \
    rm -rf /var/cache/apt/*

COPY jugendhackt-iso.sh /jugendhackt-iso.sh

CMD ["/jugendhackt-iso.sh"]
