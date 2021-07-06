APUE note 5
===========

-2015.12.13 Sherlock init: about process group, session, job, console, terminal
 this is a note about APUE charpter 9
-2015.12.14 Sherlock finish at logan airport 


最早的终端是电传打字机输入，纸带输出, 后来发展为键盘输入，显示器输出。终端在
linux下的文件是/dev/tty*, 虚拟终端/dev/tty1~6。之所以叫虚拟终端是因为/dev/tty1~6
公用一个物理的键盘和显示器。

终端无法输出系统启动的信息，所以需要用控制台输出系统启动信息用来调试系统。
控制台在linux下的文件是/dev/console, 一般控制台的物理接入是串口。

串口在linux下的文件是/dev/ttyS*

之前的终端一般由串口接入，由网络也可以接入终端，这个一般叫伪终端。像ubuntu上使用
terminal程序接入的系统的shell所对应的终端是伪终端。从这个伪终端上看，就好像是
通过一个终端接入系统的。在linux下伪终端一般表示为pts*

伪终端主设备和伪终端从设备是伪终端相关的两个重要概念。

                       (伪终端主设备)
telnet client          telnet server-------------+
      |                     |                    |
networking driver    networking driver           |
      |                     |                    |                  
networking card      networking card             |    pts/0(伪终端从设备) pts/1(伪终端从设备) ...
      |                     |
      +-----internet -------+


下面是所做的一些测试(ubuntu 14.04)

-----------
who可以查看都现在系统中的登录情况

sherlock@T440:~/notes$ who
sherlock tty2         2015-12-14 14:57
sherlock tty1         2015-12-14 14:55
sherlock :0           2015-12-14 14:44 (:0)
sherlock pts/1        2015-12-14 14:48 (:0)
sherlock pts/13       2015-12-14 14:56 (:0)

-----------
虚拟终端：tty1, tty2... tty6
echo "test" > /dev/tty1
打开虚拟终端tty1（ctrl + alt + f1）, 可以看见在屏幕上输出了"test"

-----------
在ubuntu terminal中打开的终端是伪终端，在/dev/pts/*是他们的设备文件
echo "test1" > /dev/pts/0
在伪终端上有"test1"输出


进程组, 进程组ID, 作业控制，前后台进程都是和进程相关的概念, 用ps命令可以查看这些
信息
(ctrl + z 挂起作业中的前台进程组中的所有进程)

-----------
e.g. ps -alxf (desktop ubuntu 14.04)

PPID   PID  PGID   SID TTY      TPGID STAT   UID   TIME COMMAND
...
2113  6613  2296  2296 ?           -1 Sl    1000   0:17          \_ gnome-terminal
6613  6620  2296  2296 ?           -1 S     1000   0:00          |   \_ gnome-pty-helper
6613  6621  6621  6621 pts/0     7501 Ss    1000   0:00          |   \_ bash
6621  7501  7501  6621 pts/0     7501 R+    1000   0:00          |   |   \_ ps -ajxf
6613  6648  6648  6648 pts/18    7485 Ss    1000   0:00          |   \_ bash
6648  7485  7485  6648 pts/18    7485 S+    1000   0:00          |   |   \_ vi APUE_note_5.md
6613  7435  7435  7435 pts/20    7497 Ss    1000   0:00          |   \_ bash
7435  7497  7497  7435 pts/20    7497 S+       0   0:00          |       \_ sudo grep -r wang
7497  7498  7497  7435 pts/20    7497 D+       0   0:01          |           \_ grep -r wang

如上图所示, 首先打开了Terminal的程序。Terminal下打开了三个bash, 分别对应三个
伪终端：pts/0, pts/18, pts/20. 每个bash和它的自进程都在一个session里(SID=session ID).
每个session里的情况又各有不同，比如，SID=6621 它由两个进程组组成(PGID=6621, 7501),
而SID=7435的session, 它由两个进程组组成，其中的第二个进程组又有两个进程组成

