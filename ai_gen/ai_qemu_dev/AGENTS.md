# QEMU Agent Instructions

This file provides guidelines for agentic coding agents working in the QEMU repository.

## Build Commands

### Initial Configuration
```bash
# Out-of-tree build (recommended)
mkdir build && cd build
../configure
make

# Or in-source build
./configure
make
```

### Build Targets
```bash
make                    # Build all components
make -j$(nproc)         # Parallel build
make help               # Show all targets
make recurse-all        # Build all subdirectories
```

### Testing
```bash
make check              # Run block, qapi-schema, unit, softfloat, qtest and decodetree tests
make check-unit         # Run unit tests only
make check-qapi-schema  # Run QAPI schema tests
make check-block        # Run block tests
make check-tcg          # Run TCG tests
make check-functional   # Run Python-based functional tests
make check-rust         # Run Rust tests
make bench              # Run speed/benchmark tests

# Single unit test (via meson/ninja)
cd build
ninja test              # List available tests
ninja test -v <test-name>  # Run specific test

# Or via meson directly
pyvenv/bin/meson test <test-name>
```

### Linting/Code Quality
```bash
# C code checkpatch
scripts/checkpatch.pl <patchfile>

# Python linting (from build directory)
make check-python       # or
pyvenv/bin/python -m flake8 qemu/
pyvenv/bin/python -m pylint qemu/
pyvenv/bin/python -m mypy -p qemu
pyvenv/bin/python -m isort -c qemu/

# Rust linting
make clippy
make rustfmt
make rustdoc

# Via meson devenv
pyvenv/bin/meson devenv -w ../rust cargo clippy
```

## Code Style Guidelines

### General Formatting (.editorconfig)
- **C source**: 4 spaces indent, no tabs
- **Makefiles**: 8-space tabs
- **Assembly (.s/.S)**: 8-space tabs
- **Line width**: 80 characters (warns at 100)
- **Line endings**: LF (Unix style)
- **Charset**: UTF-8

### C Code Style

#### Block Structure
```c
// Braces on same line as control statement
if (a == 5) {
    do_something();
} else if (a == 6) {
    do_other();
} else {
    do_default();
}

// Exception: function opening brace on own line
void a_function(void)
{
    do_something();
}
```

#### Variables and Types
- **Variables**: `lower_case_with_underscores`
- **Struct types**: `CamelCase`
- **Scalar types**: `lower_case_with_underscores_t` (e.g., `uint64_t`)
- **Pointers**: Always `const`-correct; use `g_autofree` for cleanup

#### Include Order
```c
#include "qemu/osdep.h"  /* Always first */
#include <...>           /* System headers */
#include "..."           /* QEMU headers */
```

#### Memory Allocation
- **ALWAYS** use GLib allocators: `g_malloc`, `g_malloc0`, `g_new`, `g_new0`, `g_realloc`, `g_free`
- Never use raw `malloc`/`free`
- Prefer `g_new(T, n)` over `g_malloc(sizeof(T) * n)`
- Use `g_try_new` for fallible allocations (large allocations, guest-triggered)

#### Error Handling
- Use `error_report()` for user-facing errors (not `printf`)
- Use `Error *` objects for propagatable errors
- Never call `exit()` or `abort()` for guest-triggerable errors
- Never exit from monitor commands

#### Comments
```c
/*
 * Multi-line comments
 * like this with stars
 */

// NOT // comments (use only /* */)
```

### Python Code Style

#### Linting Requirements
- **flake8**: Strict style checking
- **pylint**: Full linting
- **mypy**: Type checking (mandatory for new code)
- **isort**: Import sorting

#### Import Order
1. Standard library
2. Third-party packages
3. Local application imports

```python
# Standard library
import os
import sys

# Third-party
from somewhere import something

# Local
from qemu.machine import QEMUMachine
```

### Rust Code Style

#### Compiler Requirements
- **rustc**: 1.83.0 or newer
- **bindgen**: 0.60.x or newer

#### Linting
```bash
# Via Make
make clippy
make rustfmt
make rustdoc

# Via meson devenv
pyvenv/bin/meson devenv -w ../rust cargo clippy --tests
```

#### Clippy Configuration (clippy.toml)
- `doc-valid-idents`: ["IrDA", "PrimeCell", ".."]
- `msrv`: "1.83.0"

### Naming Conventions

#### C Functions
- `qemu_*`: Wrapped standard library functions or global state modifiers
- `subsystem_*`: Public functions from a subsystem (e.g., `tlb_*`, `cpu_*`)
- `*_locked`: Functions expecting lock already held
- `*_compat`: Compatibility shims
- `*_impl`: Concrete implementation (called via macro/inline)

#### Variable Names
- `cs`: CPUState pointer
- `env`: CPUArchState pointer
- `dev`: DeviceState pointer

### QEMU Object Model (QOM)
```c
struct MyDeviceState {
    DeviceState parent_obj;  /* Must be first */
    /* Properties */
    int prop_a;
    /* Internal state */
    int internal_state;
};

struct MyDeviceClass {
    DeviceClass parent_class;  /* Must be first */
    void (*new_fn1)(void);
};
```

### Trace Events Style
- Use `0x` prefix for hex numbers: `"0x%x"`
- Exception: numbers that are conventionally hex (PCI bus id): `"%x.%x.%04x"`
- Do NOT use printf `#` flag (e.g., `%#x`)

## Directory Structure

- `accel/`: Accelerator code (KVM, TCG, HVF)
- `block/`: Block device drivers
- `hw/`: Hardware emulation (organized by device type)
- `include/`: Header files
- `target/`: CPU emulation (per-architecture)
- `tests/`: Test suites (unit, qtest, functional, tcg)
- `python/`: Python libraries and tools
- `rust/`: Rust device implementations
- `scripts/`: Utility scripts (checkpatch.pl, etc.)

## Development Workflow

1. **Before submitting**: Run `scripts/checkpatch.pl <patchfile>`
2. **Build verification**: Ensure `make` succeeds
3. **Test**: Run relevant tests (`make check-unit`, `make check-qtest`)
4. **Commit format**: Include `Signed-off-by:` line

## Important Documentation

- `docs/devel/style.rst`: Full coding style guide
- `docs/devel/build-system.rst`: Build system architecture
- `docs/devel/submitting-a-patch.rst`: Patch submission guidelines
- `docs/devel/rust.rst`: Rust in QEMU guide

## Device Model Development

### From Linux Driver to QEMU Model

当需要基于Linux内核驱动开发QEMU设备模型时，参考以下文档：

- **`skill_qemu_device_model.md`**: QEMU设备模型开发完整流程，包含：
  - 分析Linux驱动的方法
  - 生成芯片手册的模板
  - QEMU模型代码骨架
  - 调试与测试技巧
  - 常见陷阱与解决方案

### 快速参考

```bash
# 分析驱动提取关键信息
# 位置: drivers/<category>/<device>.c
# 关键: probe(), pci_device_id, 寄存器偏移, MSI配置

# 开发流程
# 1. 分析驱动 → 生成手册
# 2. 创建QEMU骨架 → PCI设备框架
# 3. 实现MMIO → 寄存器读写
# 4. 实现功能逻辑 → 实际硬件模拟
# 5. 调试测试 → dmatest验证

# 常见问题
# - MSI用 msi_notify() 非 pci_set_irq()
# - sq_head/sq_tail 驱动和硬件视角不同
# - BAR0 需注册dummy避免MSI冲突
```

### 相关文件

- `skill_qemu_device_model.md`: 开发流程与模板
- `如何利用AI做QEMU模型开发.md`: 详细开发文档
- `DMA芯片手册.md`: 芯片规格参考
- `hw/dma/hisi_dma.c`: 完整实现示例
