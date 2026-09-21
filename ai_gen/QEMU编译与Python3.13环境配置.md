QEMU编译与Python3.13环境配置
===

-v0.1 2026.09.21 Sherlock init

简介：记录在openEuler 24.03 SP2(aarch64)上编译QEMU master时遇到的Python版本
问题及其解决过程。核心矛盾是QEMU要求Python >= 3.12而发行版只提供3.11.6，且
软件源中不存在更高版本。文档说明了为何增量编译仍能绕过该限制，以及如何用uv
安装预编译Python完成重新配置。


## 问题背景

QEMU master从某个版本起要求Python >= 3.12。检查逻辑位于configure脚本：

```bash
# configure:490
check_py_version() {
    # We require python >= 3.12.
    # NB: a True python conditional creates a non-zero return code (Failure)
    "$1" -c 'import sys; sys.exit(sys.version_info < (3,12))'
}
```

而openEuler 24.03 SP2仅提供python3-3.11.6，OS、everything、EPOL、update、
Charm各仓库中均不存在3.12及以上版本，dnf install python3.12无法满足。

注意，meson侧没有对应的版本门槛，meson.build中只在summary里打印
python.language_version()，不做断言。这个差异是后续绕过方案的基础。


## 增量编译为何不受影响

已有的build目录是在QEMU还接受3.11时配置的，其pyvenv和build.ninja中固化了
/usr/bin/python3.11的绝对路径。执行ninja时，重新生成构建文件走的是：

```
# build.ninja:71
rule REGENERATE_BUILD
 command = /home/wz/qemu/build/pyvenv/bin/meson --internal regenerate /home/wz/qemu .
```

该规则只调用meson --internal regenerate重新解析各meson.build，不会重跑
configure，因此Python 3.12的检查根本没有执行。结论：

```
ninja          -> 只跑meson regenerate  -> 不触发检查  -> 可以编译
./configure    -> 执行check_py_version  -> 触发检查    -> 失败
```

所以在不改动配置的前提下，直接在build目录下执行ninja -j10即可完成对当前源码
树的增量编译，无需升级Python。实测3118个步骤全部通过。


## 安装高版本Python

需要重新configure(增删target、修改编译选项、清理build目录)时，必须解决Python
版本问题。

### 方案选择

源码编译CPython存在依赖缺失问题。检查系统头文件：

| 依赖包 | 状态 | 缺失影响 |
|--------|------|----------|
| openssl-devel | 已安装 | - |
| libffi-devel | 已安装 | - |
| zlib-devel | 已安装 | - |
| ncurses-devel | 已安装 | - |
| bzip2-devel | 未安装 | 缺bz2模块 |
| xz-devel | 未安装 | 缺lzma模块 |
| sqlite-devel | 未安装 | 缺sqlite3模块 |
| readline-devel | 未安装 | REPL无行编辑 |

补装这些包需要sudo，而当前环境sudo需要密码。且meson解压subproject时可能用到
lzma，缺失存在风险。

因此选择python-build-standalone预编译二进制，它静态打包了全部依赖，不需要任何
系统dev库，也不需要sudo。通过uv安装。

### 安装uv

官方安装脚本会失败：

```bash
$ curl -LsSf https://astral.sh/uv/install.sh | sh
curl: (60) SSL certificate problem: certificate is not yet valid
```

原因是系统时钟不准，不是网络或证书本身的问题：

```
System clock synchronized: no
NTP service: inactive
Local time: 2026-09-21 13:14:47 CST
RTC time:   2026-09-22 06:06:00        <- 比系统时间快约一天
```

astral.sh证书的notBefore=Sep 21 19:45:56 2026 GMT，而系统当前UTC时间是05:14，
证书被判定为"尚未生效"。改用pip安装可绕开对astral.sh的TLS握手：

```bash
python3.11 -m pip install --user uv -i https://mirrors.huaweicloud.com/repository/pypi/simple
```

建议后续修复时钟，否则访问其他HTTPS站点仍会随机遇到证书错误：

```bash
sudo timedatectl set-ntp true
```

### 安装Python 3.13

华为云的python-build-standalone镜像不可用，请求tarball返回HTTP 401：

```bash
$ UV_PYTHON_INSTALL_MIRROR=https://mirrors.huaweicloud.com/python-build-standalone \
    uv python install 3.13
error: Failed to install cpython-3.13.15-linux-aarch64-gnu
  cause: HTTP status client error (401 ) for url (...)
```

改用npmmirror镜像成功，下载27.9MiB，耗时2.69秒：

```bash
UV_PYTHON_INSTALL_MIRROR=https://registry.npmmirror.com/-/binary/python-build-standalone \
    uv python install 3.13
```

安装路径：

```
/home/wz/.local/share/uv/python/cpython-3.13-linux-aarch64-gnu/bin/python3.13
```

注意，目录名中不含补丁版本号(是cpython-3.13而非cpython-3.13.15)，uv升级小版本
后该路径保持不变，可以安全地写进配置文件。

验证关键stdlib模块齐全：

```bash
$ python3.13 -c 'import lzma, bz2, sqlite3, ssl, ctypes; print("OK")'
OK
```


## 重新配置QEMU

原始configure参数可从build/config.status末行获取：

```bash
exec '../configure' '--target-list=aarch64-softmmu' '--enable-slirp' "$@"
```

带上新Python重新配置并编译：

```bash
cd /home/wz/qemu/build
../configure --target-list=aarch64-softmmu --enable-slirp \
  --python=/home/wz/.local/share/uv/python/cpython-3.13-linux-aarch64-gnu/bin/python3.13
ninja -j10
```

结果：

```
QEMU emulator version 11.1.50 (v11.1.0-1664-gc1c18d1e64)
build/pyvenv -> Python 3.13.15
```

QEMU的Python依赖(meson 1.12.0、pycotap、qemu.qmp)已vendor在python/wheels/下，
重新配置时不需要额外联网装包。


## build/pyvenv说明

configure会在build目录下创建一个虚拟环境，用于隔离构建期的Python依赖，避免污染
系统环境。它是构建产物，不属于QEMU源码。

```
build/pyvenv/bin/python3.13 -> /home/wz/.local/share/uv/python/
                               cpython-3.13-linux-aarch64-gnu/bin/python3.13
```

pyvenv.cfg内容：

```
home = /home/wz/.local/share/uv/python/cpython-3.13-linux-aarch64-gnu/bin
include-system-site-packages = true
version = 3.13.15
command = .../python3.13 -m venv --system-site-packages --clear
          --without-scm-ignore-files /home/wz/qemu/build/pyvenv
```

venv的bin目录下包含meson以及QEMU自带的Python工具(qmp-shell、qmp-tui、qom、
qemu-ga-client等)。config-host.mak中的PYTHON变量指向它：

```
PYTHON=/home/wz/qemu/build/pyvenv/bin/python3.13 -B
```

由于是绝对路径，ninja执行时不查PATH，构建行为不受shell环境影响。但它间接依赖
uv安装的解释器，如果执行uv python uninstall 3.13或删除
~/.local/share/uv/python/，该软链接会断裂，构建立刻失败。


## 设为默认Python

在~/.bashrc中追加(位置在opencode那段PATH之后，确保优先级最高)：

```bash
# Python 3.13 (installed via uv) as the default python / python3 / pip
UV_PY313="$HOME/.local/share/uv/python/cpython-3.13-linux-aarch64-gnu/bin"
[ -d "$UV_PY313" ] && export PATH="$UV_PY313:$PATH"
unset UV_PY313
```

加-d判断是为了目录被删除时不污染PATH。生效后：

```
python3 -> .../cpython-3.13-linux-aarch64-gnu/bin/python3   Python 3.13.15
python  -> .../bin/python
pip3    -> .../bin/pip3                                     pip 26.2.1 (python 3.13)
```

### 对已有工具的影响

系统中此前用pip --user为3.11安装过若干工具，按安装时间分批如下：

| 日期 | 工具 | 用途 |
|------|------|------|
| 2026-04-28 | edge-tts, tabulate | TTS命令行 |
| 2026-05-24 | b4, patatt, git-filter-repo | 邮件列表打补丁、提交签名 |
| 2026-07-22 | jsonschema, topdown-tool, rich | JSON校验、topdown性能分析 |
| 2026-09-08 | pypdf | PDF处理 |

这些工具不受PATH变更影响。原因是~/.local/bin下的console script使用绝对路径
shebang，不走PATH查找：

```bash
$ head -1 ~/.local/bin/b4
#!/usr/bin/python3
```

改动后实测b4 0.15.2、git-filter-repo、patatt 0.7.0、edge-tts 7.2.8、
jsonschema、topdown-tool均正常。

注意两点：

1. pip3现在指向3.13，pip3 install --user会装进
   ~/.local/lib/python3.13/site-packages。要装回3.11需显式使用
   /usr/bin/python3 -m pip install --user。
2. 旧的3.11包位于~/.local/lib/python3.11/site-packages，新的python3无法import
   它们。若需在脚本中import b4之类，要在3.13下重装一份。


## 参考文件

```
/home/wz/qemu/configure:490          check_py_version()
/home/wz/qemu/pythondeps.toml        Python依赖声明
/home/wz/qemu/python/wheels/         vendor的wheel包
/home/wz/qemu/build/config.status    原始configure参数
/home/wz/qemu/build/config-host.mak  PYTHON等变量
/home/wz/qemu/build/pyvenv/pyvenv.cfg
```


## todo

1. 修复系统时钟(启用NTP)，消除HTTPS证书"尚未生效"错误
2. 如需其他架构target，重新configure时记得带--python参数
