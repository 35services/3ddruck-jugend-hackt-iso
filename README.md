# jugendhackt-iso.sh

Bootstraps a persistent Ubuntu-based live system on a USB stick.

```shell
## setup before first run

# copy config.sample to config
cp config.sample config
# check, edit and adjust the config file to your needs (open it in an editor like nano)
nano config

## now create the sticks

# replace <usb-device> with the device path of your USB drive, e.g. /dev/sdb
jugendhackt-iso.sh <usb-device>
```

## Features

- make Ubuntu persistent on your USB
- apply a sharable configuration via a single config file
- patch installed APT and Flatpak packages
- remove Snapd
- cache patched system in order to speed up further USBs
- supports Austrian Germen *<3 Jh Linz, love you*

## Legal

This project was written for [Jugend hackt](https://jugendhackt.org), an Austrian, German and Swiss project getting youth closer to ethical technology. This project is not officially affiliated with Jugend hackt.

License: [EUPL-1.2](LICENSE)

Author: The one with the braid <the-one@with-the-braid.cf>
