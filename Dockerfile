FROM ubuntu:23.10

RUN apt-get update
RUN apt-get install -y debootstrap gdisk parted dosfstools squashfs-tools

COPY jugendhackt-iso.sh /jugendhackt-iso.sh

CMD /jugendhackt-iso.sh

