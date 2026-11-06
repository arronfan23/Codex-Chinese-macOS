#!/bin/bash
#
# build-dmg.sh —— 将 Codex 中文启动器打包为【应用程序 + DMG】
#
# 流程:
#   1. 生成 "Codex中文汉化工具.app"(osacompile 的 AppleScript 应用):
#      双击弹出图形界面(安装 / 卸载 / 使用说明),实际工作由内置的
#      codex-zh.pl 在终端窗口执行,进度实时可见;
#   2. app 经 ad-hoc 本地签名(避免结构未签名问题);
#   3. 打包为带 Finder 窗口布局的 UDZO DMG(app + 使用说明 + Applications 链接)。
#
# 输入(位于本脚本所在目录):
#   codex-zh.pl         核心工具(打进 app 的 Resources)
#   使用说明.txt        说明文档
#
# 输出:
#   build/Codex中文启动器.dmg   (可用环境变量 OUT 覆盖;自动补 .dmg 后缀)
#
# 环境变量:OUT=...  覆盖输出路径;SKIP_LAYOUT=1  跳过窗口布局
#
# 仅使用 macOS 系统自带工具:osacompile、codesign、hdiutil、osascript、ditto。
#
set -euo pipefail

# --------------------------------------------------------------------------
# 常量
# --------------------------------------------------------------------------
VOLNAME="Codex 中文启动器"
APP_NAME="Codex中文启动器.app"
FILE_README="使用说明.txt"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
BUILD_DIR="${SCRIPT_DIR}/build"
STAGING_DIR="${BUILD_DIR}/staging"
APPLESCRIPT_SRC="${BUILD_DIR}/main.applescript"

OUT="${OUT:-}"
if [ -z "${OUT}" ]; then
  OUT="${BUILD_DIR}/Codex中文启动器.dmg"
else
  case "${OUT}" in
    /*) ;;
    *) OUT="$(pwd)/${OUT}" ;;
  esac
  case "${OUT}" in
    *.dmg) ;;
    *) OUT="${OUT}.dmg" ;;
  esac
fi
SHADOW_FILE="${OUT}.shadow"
CONVERT_TMP="${OUT}.merge.tmp.dmg"
LAYOUT_ERR_FILE="${BUILD_DIR}/.layout-error.log"
MOUNT_POINT="$(/usr/bin/mktemp -d /tmp/codex-zh-dmg-mount.XXXXXX)"

info() { printf '[build-dmg] %s\n' "$*"; }
warn() { printf '[build-dmg] 警告: %s\n' "$*" >&2; }
die()  { printf '[build-dmg] 错误: %s\n' "$*" >&2; exit 1; }

as_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

cleanup() {
  local rc=$?
  /usr/bin/hdiutil detach "${MOUNT_POINT}" >/dev/null 2>&1 || true
  /bin/rm -f "${SHADOW_FILE}" "${CONVERT_TMP}" "${LAYOUT_ERR_FILE}" >/dev/null 2>&1 || true
  exit "${rc}"
}
trap cleanup EXIT

detach_mount() {
  local i=0
  while [ "${i}" -lt 4 ]; do
    if /usr/bin/hdiutil detach "${MOUNT_POINT}" >/dev/null 2>&1; then return 0; fi
    /bin/sleep 2
    i=$(( i + 1 ))
  done
  /usr/bin/hdiutil detach -force "${MOUNT_POINT}" >/dev/null 2>&1
}

# --------------------------------------------------------------------------
# 1. 校验源文件
# --------------------------------------------------------------------------
info "源目录: ${SCRIPT_DIR}"
[ -f "${SCRIPT_DIR}/codex-zh.pl" ]  || die "缺少核心工具 codex-zh.pl"
[ -s "${SCRIPT_DIR}/codex-zh.pl" ]  || die "codex-zh.pl 内容为空"
[ -f "${SCRIPT_DIR}/${FILE_README}" ] || die "缺少 ${FILE_README}"

# --------------------------------------------------------------------------
# 2. 生成 AppleScript 应用(.app)
# --------------------------------------------------------------------------
/bin/rm -rf "${BUILD_DIR}"
/bin/mkdir -p "${BUILD_DIR}" "${STAGING_DIR}" "$(dirname "${OUT}")"

info "生成应用程序:${APP_NAME}"
cat > "${APPLESCRIPT_SRC}" <<'APPLESCRIPT'
-- 确保中文版副本不在运行(重启/卸载/重装前调用)
-- 宽模式 'Contents':连 Frameworks/Resources 下残留的孤儿 helper 一起清理(不会误伤原版,原版路径不含该子串)
on quitIfRunning()
	try
		do shell script "pkill -f " & quoted form of "Codex 中文版.app/Contents" & " 2>/dev/null; sleep 2; pkill -9 -f " & quoted form of "Codex 中文版.app/Contents" & " 2>/dev/null; sleep 1; true"
	end try
end quitIfRunning

-- 原版(/Applications/ChatGPT.app)与中文版同 bundle id,共用同一份用户数据目录。
-- Electron 单实例锁互斥:原版在跑时中文版启动即静默退出(反之亦然)。
-- 所以每次启动中文版前,必须先退出原版。
on quitOriginalCodex()
	try
		do shell script "pkill -f " & quoted form of "ChatGPT.app/Contents" & " 2>/dev/null; sleep 2; pkill -9 -f " & quoted form of "ChatGPT.app/Contents" & " 2>/dev/null; sleep 1; true"
	end try
end quitOriginalCodex

-- 汉化并启动:终端里跑安装(SMO 横幅 + 渐变进度条),成功后自动打开中文版。
-- 安装前先退出旧中文版(避免对运行中的 bundle 原地重写、装完 open 只切回旧实例);
-- 安装成功后、open 前完整退出原版(Term→2s→KILL→1s,确保单实例锁已释放)。
on installAndLaunch(toolPath, destQ)
	tell application "Terminal"
		activate
		do script "pkill -f " & quoted form of "Codex 中文版.app/Contents" & " 2>/dev/null; sleep 2; pkill -9 -f " & quoted form of "Codex 中文版.app/Contents" & " 2>/dev/null; sleep 1; /usr/bin/perl " & toolPath & " install --destination " & destQ & " && { pkill -f " & quoted form of "ChatGPT.app/Contents" & " 2>/dev/null; sleep 2; pkill -9 -f " & quoted form of "ChatGPT.app/Contents" & " 2>/dev/null; sleep 1; open " & destQ & "; echo; echo '✓ 安装完成,已启动『Codex 中文版』(首次打开如提示无法验证:右键点它选打开)。'; echo; echo '---------------------------------------------'; echo '  觉得好用?欢迎去 GitHub 点个 Star 支持作者:'; echo '  https://github.com/arronfan23/Codex-Chinese-macOS'; echo '---------------------------------------------'; echo '本窗口可关闭。'; } || { echo; echo '✗ 安装未完成,请把上方信息截图反馈。原版 Codex 不受影响。本窗口可关闭。'; }; exit"
	end tell
end installAndLaunch

on run
	set myRes to POSIX path of (path to me) & "Contents/Resources/"
	set toolPath to quoted form of (myRes & "codex-zh.pl")
	set homeApp to (POSIX path of (path to home folder)) & "Applications/"
	set destApp to homeApp & "Codex 中文版.app"
	set destQ to quoted form of destApp

	-- 状态探测:是否已安装 / 中文版是否在运行 / 原版是否在运行
	-- 进程探测用窄模式只看主进程(Contents/MacOS/),避免孤儿 helper 造成误报
	set probe to do shell script "if [ -f " & destQ & "/Contents/Resources/codex-zh-install.json ]; then echo INSTALLED; else echo MISSING; fi; if pgrep -f " & quoted form of "Codex 中文版.app/Contents/MacOS/" & " >/dev/null 2>&1; then echo RUNNING; else echo STOPPED; fi; if pgrep -f " & quoted form of "/Applications/ChatGPT.app/Contents/MacOS/" & " >/dev/null 2>&1; then echo ORIG_RUNNING; else echo ORIG_IDLE; fi"
	set installState to paragraph 1 of probe
	set runState to paragraph 2 of probe
	set origState to paragraph 3 of probe

	set mainBtn to "汉化并启动"
	if installState is "INSTALLED" then
		if runState is "RUNNING" then
			set mainBtn to "重启中文版"
		else
			set mainBtn to "启动中文版"
		end if
	end if

	set statusLine to "尚未安装 —— 点『汉化并启动』开始,完成后自动打开中文版。"
	if installState is "INSTALLED" then
		if runState is "RUNNING" then
			set statusLine to "中文版已安装且正在运行。"
		else
			set statusLine to "中文版已安装,点『启动中文版』即可使用。"
		end if
	end if
	if origState is "ORIG_RUNNING" and runState is not "RUNNING" then
		set statusLine to statusLine & return & return & "⚠️ 检测到原版 Codex 正在运行:两者不能同时开,启动中文版时会自动先退出原版。"
	end if

	set msg to "SMO · Codex 中文启动器" & return & return & "· 自动识别官方 Codex 桌面版(ChatGPT / Codex)" & return & "· 完全离线:不联网、不发送任何数据" & return & "· 不动原版:独立的『Codex 中文版.app』副本" & return & "· 随时可卸载:移入废纸篓即可" & return & return & statusLine & return & return & "⭐ 觉得好用?欢迎去 GitHub 点个 Star 支持作者!(见『使用说明』)"
	display dialog msg buttons {"使用说明", "卸载汉化", mainBtn} default button mainBtn with icon note
	set act to button returned of result

	if act is "使用说明" then
		display dialog "SMO · 使用说明" & return & return & "【安装】点『汉化并启动』,终端出现 SMO 横幅与渐变进度条,走完自动打开中文版(约 1-2 分钟,完全离线)。" & return & return & "【首次打开】若提示『无法验证』或『已损坏』:右键点 app 选“打开”,或到 系统设置 → 隐私与安全性 点“仍要打开”。这是本地签名的正常现象。" & return & return & "【更新】Codex 官方更新后:先『卸载汉化』,再『汉化并启动』。原版与聊天数据不受任何影响。" & return & return & "【互斥说明】原版与中文版共用同一份数据,不能同时运行:启动中文版会自动退出原版;想用回原版,先退出中文版再打开原版即可。" & return & return & "⭐ 觉得好用?点下方按钮去 GitHub 给作者点个 Star,就是对本工具最大的支持!" buttons {"⭐ 点个 Star 支持作者", "好"} default button "好" with icon note
		if button returned of result is "⭐ 点个 Star 支持作者" then
			do shell script "open https://github.com/arronfan23/Codex-Chinese-macOS"
		end if
	else if act is "卸载汉化" then
		quitIfRunning()
		try
			do shell script "/usr/bin/perl " & toolPath & " uninstall --app " & destQ & " 2>&1"
			display dialog "SMO · 已卸载" & return & return & "『Codex 中文版』已移入废纸篓(可找回)。" & return & "原版 Codex 与聊天数据均未受影响。" buttons {"好"} default button "好" with icon note
		on error errMsg
			display dialog "SMO · 卸载未完成" & return & return & errMsg buttons {"好"} default button "好" with icon stop
		end try
	else if act is "汉化并启动" then
		installAndLaunch(toolPath, destQ)
	else if act is "启动中文版" then
		quitOriginalCodex()
		do shell script "open " & destQ
	else if act is "重启中文版" then
		quitIfRunning()
		quitOriginalCodex()
		do shell script "open " & destQ
	end if
end run
APPLESCRIPT

/usr/bin/osacompile -o "${STAGING_DIR}/${APP_NAME}" "${APPLESCRIPT_SRC}" || die "osacompile 生成应用失败"
/bin/mkdir -p "${STAGING_DIR}/${APP_NAME}/Contents/Resources"
/usr/bin/ditto "${SCRIPT_DIR}/codex-zh.pl" "${STAGING_DIR}/${APP_NAME}/Contents/Resources/codex-zh.pl"

# 应用图标:白色圆形底 + 猫头(整体圆形,圆外透明)(用户提供源图,抠底 + 泛洪分割 + 连通域清理);
# 源图缺失时回退到程序生成的绿色 Codex 风格六瓣花
ICONSET_DIR="${BUILD_DIR}/app-icon.iconset"
ICON_SRC_PNG="${BUILD_DIR}/logo-source.png"
MAKE_ICON_OK=0
if command -v node >/dev/null 2>&1; then
  if [ -f "${SCRIPT_DIR}/logo-source.jpg" ] \
     && /usr/bin/sips -s format png "${SCRIPT_DIR}/logo-source.jpg" --out "${ICON_SRC_PNG}" >/dev/null 2>&1 \
     && node "${SCRIPT_DIR}/make-icon.js" "${ICON_SRC_PNG}" "${ICONSET_DIR}" >/dev/null 2>&1; then
    MAKE_ICON_OK=1
    info "生成应用图标(按用户源图 1:1 还原)……"
  elif [ -f "${SCRIPT_DIR}/gen-logo.js" ]; then
    info "未找到源图,生成备用图标(绿色 Codex 风格)……"
    node "${SCRIPT_DIR}/gen-logo.js" "${ICONSET_DIR}" >/dev/null 2>&1 && MAKE_ICON_OK=1
  fi
  if [ "${MAKE_ICON_OK}" = "1" ] \
     && /usr/bin/iconutil -c icns -o "${STAGING_DIR}/${APP_NAME}/Contents/Resources/applet.icns" "${ICONSET_DIR}" 2>/dev/null; then
    # 关键:osacompile 生成的 Info.plist 带 CFBundleIconName + Assets.car(资产目录),
    # macOS 11+ 优先读资产目录而非 applet.icns,导致自定义 icns 被无视。
    # 移除 IconName 与 Assets.car,强制走 CFBundleIconFile → applet.icns。
    PLIST="${STAGING_DIR}/${APP_NAME}/Contents/Info.plist"
    /usr/bin/plutil -remove CFBundleIconName "${PLIST}" >/dev/null 2>&1 || true
    /bin/rm -f "${STAGING_DIR}/${APP_NAME}/Contents/Resources/Assets.car"
    info "应用图标已生成。"
  else
    warn "图标生成失败,使用默认 applet 图标(不影响功能)"
  fi
else
  warn "未找到 node,跳过自定义图标(不影响功能)"
fi

info "为应用生成本地签名(ad-hoc,无需联网)……"
if /usr/bin/codesign --force --sign - --timestamp=none "${STAGING_DIR}/${APP_NAME}" 1>/dev/null 2>&1; then
  info "应用本地签名完成。"
else
  warn "应用本地签名失败(不影响功能,首次打开需右键→打开)"
fi

/usr/bin/ditto "${SCRIPT_DIR}/${FILE_README}" "${STAGING_DIR}/${FILE_README}"
/bin/ln -sfn /Applications "${STAGING_DIR}/Applications"

[ -d "${STAGING_DIR}/${APP_NAME}" ] || die "应用生成失败"
[ -e "${STAGING_DIR}/${FILE_README}" ] || die "staging 缺少 ${FILE_README}"
[ -L "${STAGING_DIR}/Applications" ] || die "staging 缺少 Applications 链接"

# --------------------------------------------------------------------------
# 3. 生成 UDZO 镜像
# --------------------------------------------------------------------------
info "创建 DMG(UDZO): ${OUT}   卷名: ${VOLNAME}"
/usr/bin/hdiutil create \
  -volname "${VOLNAME}" \
  -srcfolder "${STAGING_DIR}" \
  -ov \
  -format UDZO \
  -fs HFS+ \
  "${OUT}" >/dev/null
[ -f "${OUT}" ] || die "hdiutil create 未生成 ${OUT}"

# --------------------------------------------------------------------------
# 4. 挂载 → Finder 窗口布局 → 卸载 → 合并布局数据
#    注:macOS 26 (Darwin 25) 的 Finder 已不接受 toolbar/statusbar 属性与
#    "item of window" 的 position / close window 写法(-10006/-1708),
#    故改用 "position of item of 卷对象",并省略 close(卸载后窗口自然消失)。
# --------------------------------------------------------------------------
if [ "${SKIP_LAYOUT:-0}" = "1" ]; then
  warn "SKIP_LAYOUT=1,跳过 Finder 窗口布局设置(产物为无布局 DMG)"
else
  info "临时挂载(影子写入模式): ${MOUNT_POINT}"
  if ! /usr/bin/hdiutil attach "${OUT}" -mountpoint "${MOUNT_POINT}" -shadow "${SHADOW_FILE}" -noverify >/dev/null; then
    die "hdiutil attach 挂载失败: ${OUT}"
  fi
  AS_MOUNT="$(as_escape "${MOUNT_POINT}")"
  AS_DISK="$(as_escape "${MOUNT_POINT##*/}")"
  AS_APP="$(as_escape "${APP_NAME}")"
  AS_README="$(as_escape "${FILE_README}")"
  if /usr/bin/osascript 2>"${LAYOUT_ERR_FILE}" <<APPLESCRIPT
tell application "Finder"
	set srcVol to (POSIX file "${AS_MOUNT}") as alias
	activate
	open srcVol
	delay 1
	set theWindow to container window of srcVol
	set current view of theWindow to icon view
	set bounds of theWindow to {140, 140, 760, 480}
	set theOptions to the icon view options of theWindow
	set arrangement of theOptions to not arranged
	set icon size of theOptions to 128
	set position of item "${AS_APP}" of srcVol to {120, 130}
	set position of item "${AS_README}" of srcVol to {330, 270}
	set position of item "Applications" of srcVol to {500, 130}
	update srcVol without registering applications
	delay 1
	return "layout-ok"
end tell
APPLESCRIPT
  then
    info "Finder 窗口布局设置完成(左:应用;右:Applications 拖放链接;下:说明)"
  else
    warn "AppleScript 设置窗口布局失败,产物降级为无布局 DMG(不影响使用)"
    [ -s "${LAYOUT_ERR_FILE}" ] && /bin/cat "${LAYOUT_ERR_FILE}" >&2 || true
  fi
  /bin/sleep 1
  info "卸载临时挂载点 ${MOUNT_POINT}"
  detach_mount || die "卸载 ${MOUNT_POINT} 失败"
  if [ -f "${SHADOW_FILE}" ]; then
    info "合并窗口布局数据 (.DS_Store) 并重打包为 UDZO"
    /usr/bin/hdiutil convert "${OUT}" -shadow "${SHADOW_FILE}" -format UDZO -ov -o "${CONVERT_TMP}" >/dev/null
    [ -f "${CONVERT_TMP}" ] || die "hdiutil convert 合并影子文件失败"
    /bin/mv -f "${CONVERT_TMP}" "${OUT}"
    /bin/rm -f "${SHADOW_FILE}"
  fi
fi

# --------------------------------------------------------------------------
# 5. 校验与摘要
# --------------------------------------------------------------------------
if /usr/bin/hdiutil verify "${OUT}" >/dev/null 2>&1; then
  info "hdiutil verify: 通过"
else
  die "hdiutil verify 未通过,镜像可能已损坏:${OUT}"
fi

info "DMG 生成完成: ${OUT}"
printf '%s\n' '---- hdiutil imageinfo 摘要 ----'
summary="$(/usr/bin/hdiutil imageinfo "${OUT}" 2>/dev/null \
  | /usr/bin/grep -E '^(Format:|Total Bytes:|Compressed Bytes:|partition-name:|Checksum Type:)' || true)"
if [ -n "${summary}" ]; then
  printf '%s\n' "${summary}"
else
  /usr/bin/hdiutil imageinfo "${OUT}" || true
fi
printf '%s\n' '--------------------------------'