#!/bin/bash
# ============================================================
#  汉化Codex.command —— Codex 桌面版中文汉化(双击安装)
#
#  原理:启用 Codex.app 官方内置但默认关闭的简体中文资源。
#  特点:完全离线、不修改原版、只创建独立的中文版副本。
#
#  依赖:本文件需与核心工具 codex-zh.pl 位于同一目录。
# ============================================================
set -euo pipefail

# 切换到本脚本所在目录(保证能找到同目录的核心工具 codex-zh.pl)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

TOOL="$SCRIPT_DIR/codex-zh.pl"

# 路径(可用环境变量 CODEX_APP / DEST 覆盖;不设 CODEX_APP 时自动识别)
CODEX_APP="${CODEX_APP:-}"
DEST="${DEST:-$HOME/Applications/Codex 中文版.app}"

# 顶部 SMO 横幅由核心工具打印(显式 banner 子命令);随后屏蔽内层重复横幅
clear || true
if [ -f "$TOOL" ]; then
    /usr/bin/perl "$TOOL" banner || true
fi
export CODEX_ZH_NO_BANNER=1
echo "            Codex 中文汉化 · 离线安装器"
echo
echo "  本工具将执行以下操作:"
echo "    1. 自动识别官方 Codex 桌面版(应用名为 ChatGPT 或 Codex);"
echo "    2. 不动原版,先完整复制一份独立副本;"
echo "    3. 只对副本启用官方内置的简体中文资源;"
echo "    4. 为副本生成本地签名(无需联网)后即可使用。"
echo
echo "  · 完全离线运行,不联网、不发送任何数据。"
echo "  · 原版应用与你的聊天数据不会受到任何影响。"
echo

EXIT_CODE=0
APP_ARGS=()
if [ -n "$CODEX_APP" ]; then
    APP_ARGS=(--app "$CODEX_APP")
fi

if [ ! -f "$TOOL" ]; then
    echo "错误:未找到核心工具 codex-zh.pl。"
    echo "请保持本文件夹内容完整(不要把 .command 文件单独拷出去)后重试。"
    EXIT_CODE=1
elif [ -e "$DEST" ]; then
    echo "错误:目标位置已存在,无法重复安装。"
    echo "  $DEST"
    echo
    echo "如需重新安装,请先双击『卸载汉化.command』删除旧的中文版副本,"
    echo "再重新运行本工具。"
    EXIT_CODE=1
else
    echo "目标位置:$DEST"
    echo
    # bash 3.2 + set -u 下空数组 "${APP_ARGS[@]}" 会报 unbound,需用 + 展开惯用法
    if /usr/bin/perl "$TOOL" install ${APP_ARGS[@]+"${APP_ARGS[@]}"} --destination "$DEST"; then
        echo
        echo "======================================================"
        echo "  安装完成!"
        echo "======================================================"
        echo "请打开个人应用文件夹($HOME/Applications),"
        echo "找到『Codex 中文版.app』并双击运行。"
        echo "首次打开如提示“无法验证”或“已损坏”,请参阅《使用说明.txt》。"
    else
        echo
        echo "安装失败:请根据上方错误信息排查后重试。"
        echo "原版 Codex.app 未被修改,可放心继续使用原版。"
        EXIT_CODE=1
    fi
fi

echo
echo "------------------------------------------------------"
printf '按回车键关闭本窗口…'
read -r || true
exit "$EXIT_CODE"
