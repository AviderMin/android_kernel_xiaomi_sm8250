#!/bin/bash

# 颜色定义
yellow='\033[0;33m'
white='\033[0m'
red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
purple='\033[0;35m'
cyan='\033[0;36m'

# 输出带颜色的消息函数
color_echo() {
    local color=$1
    shift
    echo -e "${color}$*${white}"
}

# 确保脚本在出错时退出
set -e

# 参数处理
TARGET_DEVICE=""
KERNEL_NAME="Nijika"
KERNEL_VERSION="v1.6"
USE_KSU=true       # 默认启用 KSU
CCACHE_ENABLED=true
NO_CLEAN=false
USE_THINLTO=true   # 默认开启 ThinLTO
MAKE_FLAGS=""

TARGET_DEVICE="$1"
shift || true

# 处理选项参数
while [ $# -gt 0 ]; do
    case "$1" in
        --noccache)
            CCACHE_ENABLED=false
            shift
            ;;
        --noclean)
            NO_CLEAN=true
            shift
            ;;
        --nothinlto)
            USE_THINLTO=false
            shift
            ;;
        --noksu)
            USE_KSU=false
            shift
            ;;
        --)
            shift
            MAKE_FLAGS="$*"
            break
            ;;
        *)
            color_echo "$yellow" "忽略未知选项: $1"
            shift
            ;;
    esac
done

# 工具链路径变量，默认系统环境clang
CLANG_PATH=${CLANG_PATH:-clang}
#CLANG_PATH="${HOME}/clang-12/bin/clang"

# 检查必需的工具链
check_toolchain() {
    local tool=$1
    local install_cmd=$2
    if ! command -v "$tool" >/dev/null 2>&1; then
        color_echo "$red" "错误: [$tool] 未找到，请检查你的环境或设置 CLANG_PATH"
        color_echo "$yellow" "尝试安装: $install_cmd"
        exit 1
    fi
}

check_toolchain "aarch64-linux-gnu-ld" "sudo apt install binutils-aarch64-linux-gnu"
check_toolchain "arm-linux-gnueabi-ld" "sudo apt install binutils-arm-linux-gnueabi"
check_toolchain "$CLANG_PATH" "sudo apt install clang"

# 设置ccache
if $CCACHE_ENABLED; then
    export CCACHE_DIR="${HOME}/.cache/ccache_mikernel"
    export CC="gcc clang"
    export CXX="g++ clang"
    export PATH="/usr/lib/ccache:$PATH"
    color_echo "$green" "已启用 ccache | 缓存目录: [$CCACHE_DIR]"
else
    color_echo "$yellow" "警告: 已禁用 ccache，编译速度可能降低"
fi

# 设置环境变量
export ARCH=arm64
export SUBARCH=arm64
export KBUILD_BUILD_HOST=$(hostname)
export KBUILD_BUILD_USER=$(whoami)
export LLVM=1
export LLVM_IAS=0
export AS=aarch64-linux-gnu-as
export LD=aarch64-linux-gnu-ld
export OBJCOPY=aarch64-linux-gnu-objcopy
export OBJDUMP=aarch64-linux-gnu-objdump
export STRIP=aarch64-linux-gnu-strip

# 设置编译参数，使用变量CLANG_PATH
MAKE_ARGS="O=out CC=${CLANG_PATH}"
MAKE_ARGS+=" CROSS_COMPILE=aarch64-linux-gnu-"
MAKE_ARGS+=" CROSS_COMPILE_ARM32=arm-linux-gnueabi-"
MAKE_ARGS+=" CROSS_COMPILE_COMPAT=arm-linux-gnueabi-"
MAKE_ARGS+=" CLANG_TRIPLE=aarch64-linux-gnu-"

# 检查设备配置是否存在
if [[ ! -f "arch/arm64/configs/${TARGET_DEVICE}_defconfig" ]]; then
    color_echo "$red" "错误: 未找到目标设备 [$TARGET_DEVICE] 的配置"
    color_echo "$yellow" "可用设备配置:"
    ls arch/arm64/configs/*_defconfig | sed "s/.*\///; s/_defconfig//" | xargs printf "  %s\n"
    exit 1
fi

# 显示环境信息
color_echo "$yellow" "目标设备: $TARGET_DEVICE"
color_echo "$yellow" "编译选项: $MAKE_FLAGS"

color_echo "$green" "[clang 版本信息]:"
${CLANG_PATH} --version


# 清理工作区
if ! $NO_CLEAN; then
    color_echo "$yellow" "清理工作区..."
    rm -rf out/
else
    color_echo "$yellow" "跳过清理步骤..."
fi

# 添加日期到本地版本
LOCAL_VERSION_STR="-perf"
LOCAL_VERSION_DATE="-${KERNEL_NAME}-${KERNEL_VERSION}-$(date +%Y%m%d)"

sed -i "s/${LOCAL_VERSION_STR}/${LOCAL_VERSION_DATE}/g" "arch/arm64/configs/${TARGET_DEVICE}_defconfig"

# 配置内核
color_echo "$green" "配置 ${TARGET_DEVICE}_defconfig..."
make $MAKE_ARGS "${TARGET_DEVICE}_defconfig"

# 根据 KSU 启用/禁用配置
if $USE_KSU; then
    color_echo "$green" "启用 KernelSU..."
    ./scripts/config --file out/.config \
        -e KSU \
        -e KSU_MANUAL_HOOK \
        -e KSU_SUSFS_HAS_MAGIC_MOUNT \
        -e KSU_SUSFS_SUS_MOUNT \
        -e KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT \
        -e KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT \
        -e KSU_SUSFS_SUS_KSTAT \
        -e KSU_SUSFS_TRY_UMOUNT \
        -e KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT \
        -e KSU_SUSFS_SPOOF_UNAME \
        -e KSU_SUSFS_ENABLE_LOG \
        -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
        -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
else
    color_echo "$yellow" "禁用 KSU..."
    ./scripts/config --file out/.config \
        -d KSU \
        -d KSU_MANUAL_HOOK \
        -d KSU_SUSFS_HAS_MAGIC_MOUNT \
        -d KSU_SUSFS_SUS_MOUNT \
        -d KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT \
        -d KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT \
        -d KSU_SUSFS_SUS_KSTAT \
        -d KSU_SUSFS_TRY_UMOUNT \
        -d KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT \
        -d KSU_SUSFS_SPOOF_UNAME \
        -d KSU_SUSFS_ENABLE_LOG \
        -d KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
        -d KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG
fi

# 处理LTO配置
if $USE_THINLTO; then
    color_echo "$green" "启用 ThinLTO..."
    ./scripts/config --file out/.config -e LTO_CLANG -e THINLTO -d LTO_NONE
else
    color_echo "$yellow" "禁用 ThinLTO..."
    ./scripts/config --file out/.config -e LTO_CLANG -d THINLTO -d LTO_NONE
fi

make $MAKE_ARGS olddefconfig

# 记录开始时间
START_TIME=$(date +%s)

# 编译内核
color_echo "$green" "开始编译内核..."
make $MAKE_ARGS -j$(nproc) $MAKE_FLAGS

# 检查编译结果
IMAGE_PATH="out/arch/arm64/boot/Image"
if [[ ! -f "$IMAGE_PATH" ]]; then
    color_echo "$red" "错误: 未找到内核镜像 [$IMAGE_PATH]，编译失败"
    exit 1
fi

# 计算编译时间
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
MINUTES=$((DURATION / 60))
SECONDS=$((DURATION % 60))

color_echo "$green" "编译成功! 耗时: ${MINUTES}分${SECONDS}秒"

# 生成DTB
DTB_PATH="out/arch/arm64/boot/dtb"
color_echo "$green" "生成DTB文件 [$DTB_PATH]..."
find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + > "$DTB_PATH"

# 处理AnyKernel3
if [[ ! -d "anykernel" ]]; then
    color_echo "$green" "克隆 AnyKernel3..."
    git clone https://github.com/liyafe1997/AnyKernel3 -b kona --single-branch --depth=1 anykernel
else
    color_echo "$yellow" "AnyKernel3 目录已存在，跳过克隆"
fi

color_echo "$green" "准备 AnyKernel3 文件..."
rm -rf anykernel/kernels/
mkdir -p anykernel/kernels/
cp "$IMAGE_PATH" anykernel/kernels/
cp "$DTB_PATH" anykernel/kernels/

# 创建ZIP文件名
KSU_STR=$($USE_KSU && echo "SU" || echo "NoSU")
ZIP_NAME="${TARGET_DEVICE}_${KERNEL_NAME}-${KERNEL_VERSION}_${KSU_STR}_$(date +'%Y%m%d_%H%M%S').zip"

color_echo "$green" "创建刷机包: $ZIP_NAME"
(cd anykernel && zip -r9 "$ZIP_NAME" ./* -x .git .gitignore out/ ./*.zip)

# 创建输出目录
OUTPUT_DIR="../${TARGET_DEVICE}_Release"
mkdir -p "$OUTPUT_DIR"
mv "anykernel/$ZIP_NAME" "$OUTPUT_DIR/"

color_echo "$green" "完成! 刷机包已保存到: [$OUTPUT_DIR/$ZIP_NAME]"

# 恢复本地版本字符串
sed -i "s/${LOCAL_VERSION_DATE}/${LOCAL_VERSION_STR}/g" "arch/arm64/configs/${TARGET_DEVICE}_defconfig"
