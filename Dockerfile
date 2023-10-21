FROM ubuntu:23.10

RUN apt-get update
RUN apt-get install -y debootstrap gdisk parted dosfstools squashfs-tools udev
RUN rm -rf /var/cache/apt/*

COPY jugendhackt-iso.sh /jugendhackt-iso.sh

WORKDIR /
CMD /jugendhackt-iso.sh

