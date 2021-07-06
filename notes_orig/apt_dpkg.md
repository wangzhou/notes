apt、dpkg命令学习笔记
=====================

v0.1 2014.1.12 wangzhou apt、dpkg命令总结

简介：apt、dpkg是使用ubuntu系统常用的软件包管理的工具。他们可以完成软件的自动
      下载和安装。本文介绍他们的一些用法

原理：ubuntu是linux系统的一个发行版，其实在debian上修改而来。最开始debian的软
      件包管理命令是dpkg, 这个命令可以安装单个软件包，也可以对现有的软件包做
      一些查找之类的工作。但是dpkg命令只能处理单个deb包的情况，对于安装的软件
      要依赖其他包的情况debian开发了apt工具。ubuntu的包管理也是使用apt, ubuntu
      在全球范围内维护很多个软件仓库，这些仓库中的软件包都是一样的，使用apt命令
      的时候就是从这些软件仓库的其中之一去下载软件包并安装，这些软件仓库的URL保
      存在本地ubuntu的/etc/apt/source.list中
	  
下面以例子的形式介绍具体的用法：

1. 下载自己ubuntu上的ls的源代码:
   which ls 得到ls命令对应的二进制文件的路径: /bin/ls
   dpkg -S /bin/ls 查找是什么deb包包含/bin/ls, 若只用ls会有很多无用的查找结果
                   该命令的到的结果: coreutils: /bin/ls
   sudo apt-get search coreutils 下载coreutils包的源代码

2. sudo apt-get update 更新软件仓库

3. sudo apt-get upgrade 更新已经安装的软件到最新的版本

4. dpkg -i ***.deb 安装一个deb包到系统

5. sudo apt-get install *** 安装软件***，如果有依赖的包没有，其会自动下载需要依
   赖的包，然后安装软件

6. sudo apt-get remove *** 卸载软件***

7. 升级ubuntu内核：ubuntu的内核差最新的内核比较远，怎么更新到最新的内核?
   http://kernel.ubuntu.com/~kernel-ppa/mainline/ 有各个kernel版本的deb包, 选择
   喜欢的一个进去，作为例子这里选v3.13-rc1-trusty
   如果pc是64位的，下载linux-image-***amd64.deb, linux-headers-***amd64.deb
   linux-header-***all.deb三个deb包
   dpkg -i ***.deb分别安装这三个包，然后sudo update_grub更新grub
   重启电脑后会发现kernel已经更新到3.13



