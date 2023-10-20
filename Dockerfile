FROM ubuntu:23.10

RUN apt-get update
RUN apt-get install -y debootstrap gdisk parted dosfstools squashfs-tools udev

COPY jugendhackt-iso.sh /jugendhackt-iso.sh

WORKDIR /
CMD /jugendhackt-iso.sh

