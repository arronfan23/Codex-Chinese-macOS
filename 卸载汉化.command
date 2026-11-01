#!/bin/bash
# ============================================================
#  卸载汉化.command —— 删除本工具创建的『Codex 中文版.app』
#
#  只删除由『汉化Codex.command』创建的中文版副本(移入废纸篓),
#  不影响原版 Codex.app,也不影响聊天记录与任何个人数据。
#
#  依赖:本文件需与核心工具 codex-zh.pl 位于同一目录。
# ============================================================
set -euo pipefail

# 切换到本脚本所在目录(保证能找到同目录的核心工具 codex-zh.pl)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

TOOL="$SCRIPT_DIR/codex-zh.pl"

# 中文版副本路径(与安装器默认一致,可用环境变量 DEST 覆盖)
DEST="${DEST:-$HOME/Applications/Codex 中文版.app}"

# 顶部 SMO 横幅由核心工具打印(显式 banner 子命令);随后屏蔽内层重复横幅
clear || true
if [ -f "$TOOL" ]; then
    /usr/bin/perl "$TOOL" banner || true
fi
export CODEX_ZH_NO_BANNER=1
echo "            Codex 中文汉化 · 卸载"
echo
echo "  本工具只会删除由『汉化Codex.command』创建的中文版副本"
echo "  (通过 Finder 移入废纸篓,可随时从废纸篓找回):"
echo "    $DEST"
echo
echo "  · 原版 Codex.app 不会被修改或删除;"
echo "  · 你的聊天记录与个人数据不受任何影响。"
echo

EXIT_CODE=0

if [ ! -f "$TOOL" ]; then
    echo "错误:未找到核心工具 codex-zh.pl。"
    echo "请保持本文件夹内容完整(不要把 .command 文件单独拷出去)后重试。"
    EXIT_CODE=1
elif [ ! -d "$DEST" ]; then
    echo "未发现中文版副本,无需卸载。"
    echo "  (已检查:$DEST)"
    echo "  提示:若安装时自定义过目标位置,请先在“终端”运行:"
    echo "        DEST=/实际路径/Codex\ 中文版.app ./卸载汉化.command"
else
    if /usr/bin/perl "$TOOL" uninstall --app "$DEST"; then
        echo
        echo "======================================================"
        echo "  卸载完成!"
        echo "======================================================"
        echo "中文版副本已移入废纸篓。"
        echo "原版 Codex.app 与聊天数据均未受影响。"
    else
        echo
        echo "卸载失败:请根据上方错误信息排查后重试。"
        echo "若此前手动改动过中文版副本,可直接在 Finder 中将其移入废纸篓,"
        echo "同样不会影响原版与聊天数据。"
        EXIT_CODE=1
    fi
fi

echo
echo "------------------------------------------------------"
printf '按回车键关闭本窗口…'
read -r || true
exit "$EXIT_CODE"
