#!/bin/bash
# -i is to build Image
# -d is to build dtb: 660 1610 d03
# -s is to send Image
# -f is to send dtb
#
# getopts is a built in command
# reference: http://wiki.bash-hackers.org/howto/getopts_tutorial
#
#
#
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
BUILD_IMAGE=0
BUILD_DTB=0
IF_SEND_IMAGE=0
IF_SEND_DTB=0

while getopts "id:sf" opt; do
	case $opt in
		i)
			BUILD_IMAGE=1
			;;
		d)
			BUILD_DTB=$OPTARG
			;;
		s)
			IF_SEND_IMAGE=1
			;;
		f)
			IF_SEND_DTB=1
			;;
	esac
done

if [ $BUILD_IMAGE == 1 ]; then
	make -j24 Image
fi

if [ $BUILD_DTB -ne 0 ]; then
	case $BUILD_DTB in
		660)
			make hisilicon/hip05-d02.dtb
			;;
		1610)
			make hisilicon/hip06-evb.dtb
			;;
		1612)
			make hisilicon/hip06-d03.dtb
			;;
	esac
fi

if [ $IF_SEND_IMAGE == 1 ]; then
	scp ./arch/arm64/boot/Image wangzhou@192.168.1.107:/home/wangzhou/tftp
fi

if [ $IF_SEND_DTB == 1 ]; then
	if [ $BUILD_DTB -ne 0 ]; then
		case $BUILD_DTB in
			660)
				scp ./arch/arm64/boot/dts/hisilicon/hip05-d02.dtb wangzhou@192.168.1.107:/home/wangzhou/tftp
				;;
			1610)
				scp ./arch/arm64/boot/dts/hisilicon/hip06-evb.dtb wangzhou@192.168.1.107:/home/wangzhou/tftp
				;;
			1612)
				scp ./arch/arm64/boot/dts/hisilicon/hip06-d03.dtb wangzhou@192.168.1.107:/home/wangzhou/tftp
				;;
		esac
	fi
fi
