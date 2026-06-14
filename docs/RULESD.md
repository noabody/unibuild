# find joystick event#

```shell
readlink /dev/input/by-id/*event-joy* | grep -Pio '\d+$'
```

# udevadm /dev/input

```shell
evdev-joystick --l
udevadm info -a -n /dev/input/event19
udevadm info --query=name --name=/dev/input/dualshock3 | grep -Pio '\d+'
udevadm info -a -n /dev/input/ipega9069 | grep -Pio '(?<=ATTRS{name}==").*(?=")|(?<=ATTRS{uniq}==").*(?=")'
sudo udevadm control --reload-rules && udevadm trigger
```

# calibrate joystick

```shell
sudo jscal-store /dev/input/js0
cat /var/lib/joystick/joystick.state
```

# bluetooth SDL joystick

```shell
export SDL_JOYSTICK_DEVICE=/dev/input/ipega9069
export SDL_JOYSTICK_DEVICE=/dev/input/dualshock3
```

# udev rules

## Notice how devices that were created at the same time are often multiple instances of the same device.

```shell
ls -al /dev/input/
crw-rw----   1 root input 13, 84 Nov  3 13:11 event20
crw-rw----   1 root input 13, 85 Nov  3 13:11 event21
crw-rw----+  1 root input 13, 86 Nov  3 13:11 event22
crw-rw----+  1 root input 13, 67 Nov  3 11:21 event3
crw-rw-r--+  1 root input 13,  0 Nov  3 11:21 js0
crw-rw-r--+  1 root input 13,  1 Nov  3 13:11 js1

udevadm info -an /dev/input/event22
  looking at device '/devices/pci0000:00/0000:00:10.1/usb8/8-1/8-1:1.0/bluetooth/hci0/hci0:71/0005:054C:09CC.000F/input/input44/event22':
    KERNEL=="event22"
    SUBSYSTEM=="input"
    DRIVER==""

  looking at parent device '/devices/pci0000:00/0000:00:10.1/usb8/8-1/8-1:1.0/bluetooth/hci0/hci0:71/0005:054C:09CC.000F/input/input44':
    KERNELS=="input44"
    SUBSYSTEMS=="input"
    DRIVERS==""
    ATTRS{name}=="Wireless Controller"
    ATTRS{phys}=="00:1b:41:a4:ec:42"
    ATTRS{properties}=="0"
    ATTRS{uniq}=="dc:0c:2d:6f:c3:4d"

  looking at parent device '/devices/pci0000:00/0000:00:10.1/usb8/8-1/8-1:1.0/bluetooth/hci0/hci0:71/0005:054C:09CC.000F':
    KERNELS=="0005:054C:09CC.000F"
    SUBSYSTEMS=="hid"
    DRIVERS=="sony"
    ATTRS{bt_poll_interval}=="4"
    ATTRS{country}=="00"
```

- Our rule requires a symlink in ```/dev/input/``` which means we must match against ```SUBSYSTEM input```. This limits the rule somewhat as we can either use information from that level or move downward.  The next viable option is to match against information in ```SUBSYSTEMS input```.  Beyond that we can also match in ```SUBSYSTEMS hid``` but going much farther down isn't particulary viable or helpful.

## When a device has multiple vid/pid (054c/09cc) events such as controller, touchpad, sensors, the following rule is best.

```
SUBSYSTEM=="input", SUBSYSTEMS=="input", ATTRS{name}=="Wireless Controller", TAG+="uaccess", SYMLINK+="input/ps4ds4", ENV{ID_INPUT_JOYSTICK}="1"
```


## When a device has only one vid/pid the follwing rule is best.

```
SUBSYSTEM=="input", SUBSYSTEMS=="hid", KERNELS=="0005:054C:09CC.*", TAG+="uaccess", SYMLINK+="input/ps4ds4", ENV{ID_INPUT_JOYSTICK}="1"
```


## To pull info directly from "looking at parent device"...

```shell
udevadm info -ap /devices/pci0000:00/0000:00:10.1/usb8/8-1/8-1:1.0/bluetooth/hci0/hci0:71/0005:054C:09CC.000F/input/input44
```
