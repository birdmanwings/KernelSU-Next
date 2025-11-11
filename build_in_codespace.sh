#!/bin/bash

# 在 GitHub Codespaces 中快速编译 KernelSU 模块
# 使用方法: ./build_in_codespace.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="$SCRIPT_DIR/android-kernel"

echo "╔════════════════════════════════════════════════╗"
echo "║  KernelSU LKM 快速编译 (Codespaces/Linux)     ║"
echo "╚════════════════════════════════════════════════╝"
echo

# 检查是否在 Linux 环境
if [[ ! "$(uname)" == "Linux" ]]; then
    echo "❌ 此脚本只能在 Linux 环境运行"
    echo "请使用 GitHub Codespaces 或其他 Linux 虚拟机"
    exit 1
fi

# 安装依赖（只在首次运行）
if ! command -v repo &> /dev/null; then
    echo "[1/6] 安装构建依赖..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        bc bison build-essential ccache curl flex \
        g++-multilib gcc-multilib git gnupg gperf \
        lib32ncurses5-dev lib32z1-dev libc6-dev-i386 \
        libelf-dev libfl-dev libncurses5 libncurses5-dev \
        libssl-dev make python3 python3-pip rsync \
        schedtool squashfs-tools unzip wget zip zlib1g-dev
    
    # 安装 repo
    mkdir -p ~/.bin
    curl https://storage.googleapis.com/git-repo-downloads/repo > ~/.bin/repo
    chmod a+x ~/.bin/repo
    export PATH=~/.bin:$PATH
    echo "✓ 依赖已安装"
else
    echo "[1/6] ✓ 依赖已就绪"
fi

# 下载内核源码（如果不存在）
if [ ! -d "$KERNEL_DIR/common" ]; then
    echo
    echo "[2/6] 下载内核源码..."
    echo "  这可能需要 10-20 分钟..."
    
    mkdir -p "$KERNEL_DIR"
    cd "$KERNEL_DIR"
    
    ~/.bin/repo init --depth=1 \
        -u https://android.googlesource.com/kernel/manifest \
        -b common-android14-5.15-2024-06 \
        --repo-rev=v2.16
    
    # 修正 deprecated 分支
    sed -i 's/revision="android14-5.15-2024-06"/revision="deprecated\/android14-5.15-2024-06"/g' \
        .repo/manifests/default.xml
    
    ~/.bin/repo sync -c -j$(nproc) --no-tags
    echo "✓ 源码下载完成 ($(du -sh . | cut -f1))"
else
    echo "[2/6] ✓ 源码已存在 ($(du -sh $KERNEL_DIR | cut -f1))"
fi

# 集成 KernelSU
echo
echo "[3/6] 集成 KernelSU..."
cd "$KERNEL_DIR/common"

if [ ! -L "KernelSU" ]; then
    ln -sf "$SCRIPT_DIR/kernel" ./KernelSU
    cd drivers
    ln -sf ../KernelSU ./kernelsu
    
    # 修改 Makefile
    if ! grep -q "CONFIG_KSU" Makefile; then
        echo 'obj-$(CONFIG_KSU) += kernelsu/' >> Makefile
    fi
    
    # 修改 Kconfig
    if ! grep -q "KernelSU/Kconfig" Kconfig; then
        sed -i '/source "drivers\/most\/Kconfig"/a source "drivers/KernelSU/Kconfig"' Kconfig
    fi
    
    echo "✓ KernelSU 已集成"
else
    echo "✓ KernelSU 已存在"
fi

# 配置编译环境
echo
echo "[4/6] 配置编译环境..."
cd "$KERNEL_DIR"

export ARCH=arm64
export SUBARCH=arm64
export CLANG_TRIPLE=aarch64-linux-gnu-
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
export CROSS_COMPILE_COMPAT=arm-linux-gnueabi-

# 使用 prebuilts 中的编译器
CLANG_PATH="$KERNEL_DIR/prebuilts/clang/host/linux-x86/clang-r487747c"
if [ -d "$CLANG_PATH" ]; then
    export PATH="$CLANG_PATH/bin:$PATH"
    export CC="$CLANG_PATH/bin/clang"
    export LD="$CLANG_PATH/bin/ld.lld"
    export AR="$CLANG_PATH/bin/llvm-ar"
    export NM="$CLANG_PATH/bin/llvm-nm"
    export OBJCOPY="$CLANG_PATH/bin/llvm-objcopy"
    export OBJDUMP="$CLANG_PATH/bin/llvm-objdump"
    export READELF="$CLANG_PATH/bin/llvm-readelf"
    export STRIP="$CLANG_PATH/bin/llvm-strip"
    echo "✓ 使用 Android Clang"
else
    echo "⚠️  未找到 Android Clang，使用系统编译器"
fi

export LKM_BUILD=1
export KSUNAME="KernelSU-Next"

# 开始编译
echo
echo "[5/6] 开始编译 kernelsu.ko..."
echo "  CPU 核心数: $(nproc)"
echo "  预计时间: 10-15 分钟"
echo

cd "$KERNEL_DIR"

# 尝试使用 build.sh
if [ -f "build/build.sh" ]; then
    echo "使用 Android 官方构建脚本..."
    BUILD_CONFIG=common/build.config.gki.aarch64 build/build.sh CONFIG_KSU=m
else
    # 手动编译
    echo "使用手动编译方式..."
    cd common
    
    make gki_defconfig
    scripts/config --module CONFIG_KSU
    
    make -j$(nproc) modules_prepare
    make -j$(nproc) M=drivers/kernelsu modules
fi

# 查找编译产物
echo
echo "[6/6] 查找编译产物..."

KO_FILE=$(find "$KERNEL_DIR" -name "kernelsu.ko" 2>/dev/null | head -1)

if [ -n "$KO_FILE" ]; then
    echo
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ 编译成功！"
    echo
    echo "📦 kernelsu.ko 位置:"
    echo "   $KO_FILE"
    echo
    ls -lh "$KO_FILE"
    echo
    echo "🔧 模块信息:"
    modinfo "$KO_FILE" 2>/dev/null | grep -E "filename|version|description" || true
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "📱 部署命令:"
    echo "   # 下载到本地"
    echo "   gh codespace cp remote:$KO_FILE kernelsu.ko"
    echo
    echo "   # 或通过 adb 直接部署"
    echo "   adb push $KO_FILE /data/local/tmp/"
    echo "   adb shell su -c 'insmod /data/local/tmp/kernelsu.ko'"
    
    # 复制到易访问位置
    cp "$KO_FILE" "$SCRIPT_DIR/kernelsu.ko"
    echo
    echo "✓ 已复制到: $SCRIPT_DIR/kernelsu.ko"
else
    echo "❌ 未找到 kernelsu.ko"
    echo
    echo "查找所有 .ko 文件:"
    find "$KERNEL_DIR" -name "*.ko" 2>/dev/null | head -10
    exit 1
fi
