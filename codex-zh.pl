#!/usr/bin/perl
# ============================================================================
#  codex-zh.pl —— Codex 桌面版离线中文汉化工具(脚本版)
#
#  原理(复刻 Codex中文汉化补丁 V37 的机制):
#    官方 Codex.app(Electron)自带完整简体中文资源
#    (app.asar 内 native-menu-locales/zh-CN.json 与 webview/assets/zh-CN-*),
#    但被 feature flag 锁死、locale 默认英文。本工具对副本 app.asar 内的 JS
#    做三处【等长】替换以启用中文,并同步完整性记录后本地重签名:
#      R1  x?.get(`enable_i18n`,!1)  →  !1 改 !0(启用 i18n;反引号为真实字符)
#      R2  f(v.localeOverride)       →  参数替换为 "zh-CN"+空格填充(等长)
#      R3  o.getEffective(v.localeOverride.key) → 同上
#    等长原则保证 asar 偏移与头尺寸不变,可原位更新 integrity 哈希。
#
#  子命令:
#    inspect   [--app /Applications/Codex.app] [--json]
#    install   [--app ...] [--destination ~/Applications/Codex 中文版.app]
#    uninstall --app <中文版副本路径>
#    selftest  [--keep]
#
#  仅依赖 macOS 系统自带组件:perl(Digest::SHA/JSON::PP)、plutil、codesign、
#  ditto、osascript、xattr。全程离线,不修改原版应用。
# ============================================================================
use strict;
use warnings;

use Digest::SHA ();
use JSON::PP ();
use File::Find qw(find);
use File::Copy qw(copy);
use File::Basename qw(basename dirname);
use File::Spec ();
use POSIX qw(strftime);

# ----------------------------------------------------------------------------
# 常量
# ----------------------------------------------------------------------------
my $BUNDLE_ID      = 'com.openai.codex';
my $LANGUAGE       = 'zh-CN';   # 注入 JS 的字面量;含双引号共 7 字节
my $BLOCK_SIZE     = 4194304;   # asar integrity 块大小(4 MiB)
my $MANIFEST_NAME  = 'codex-zh-install.json';
my $STAGE_SUFFIX   = '.zh-stage';

# 三条补丁正则(与 V37 二进制中的常量一致;enable_i18n 两侧为反引号 U+0060)
my $RE_FLAG_OFF = qr/\b[A-Za-z_\$][A-Za-z0-9_\$]*\?\.get\(\x60enable_i18n\x60,!1\)/;
my $RE_FLAG_ON  = qr/\b[A-Za-z_\$][A-Za-z0-9_\$]*\?\.get\(\x60enable_i18n\x60,!0\)/;
my $RE_LOCALE   = qr/\b([A-Za-z_\$][A-Za-z0-9_\$]*)\(([A-Za-z_\$][A-Za-z0-9_\$]*)\.localeOverride\)/;
my $RE_EFFECT   = qr/\b([A-Za-z_\$][A-Za-z0-9_\$.]*)\.getEffective\(([A-Za-z_\$][A-Za-z0-9_\$.]*)\.localeOverride\.key\)/;

# asar 内的补丁目标文件(路径前缀;覆盖新旧两代布局)
#   旧版主进程:.vite/build/main*;新版(如 26.x):.vite/build/early-bootstrap*
#   旧版 webview 初始化:app-initial-*;新版 i18n 开关/语言消费:
#   initialize-app-host-services-* / general-settings-*
our @PATCH_TARGETS = (
    '.vite/build/main',
    '.vite/build/early-bootstrap',
    'webview/assets/app-initial-',
    'webview/assets/initialize-app-host-services',
    'webview/assets/general-settings',
);
# locale 资源存在性检查
our $LOCALE_MARKER_FILE   = 'native-menu-locales/zh-CN.json';
our $LOCALE_MARKER_PREFIX = 'webview/assets/zh-CN-';

my $ASAR_REL  = 'Contents/Resources/app.asar';
my $PLIST_REL = 'Contents/Info.plist';

# ----------------------------------------------------------------------------
# 小工具
# ----------------------------------------------------------------------------
sub u32le { return unpack('V', substr($_[0], 0, 4)); }
sub fail  { die "错误:$_[0]\n"; }
sub info  { print "[codex-zh] $_[0]\n"; }

sub slurp {
    my ($p) = @_;
    open my $fh, '<:raw', $p or fail "无法读取 $p:$!";
    local $/;
    my $d = <$fh>;
    close $fh;
    return defined $d ? $d : '';
}

sub spew_raw {
    my ($p, $d) = @_;
    # 拒绝写入符号链接,防止穿透到副本之外(含原版应用)
    fail "目标是指向外部的符号链接,已停止以保护原文件:$p" if -l $p;
    open my $fh, '>:raw', $p or fail "无法写入 $p:$!";
    print {$fh} $d;
    close $fh or fail "无法关闭 $p:$!";
}

sub shell_quote {
    my ($s) = @_;
    $s =~ s/([\\\"`\$])/\\$1/g;
    return "\"$s\"";
}

# 执行外部命令(soft=1 时失败仅返回 0)
sub run_cmd {
    my ($cmd, %opt) = @_;
    my $full = join(' ', map { shell_quote($_) } @$cmd);
    $full .= ' 1>/dev/null 2>&1';
    my $rc = system($full);
    if ($rc != 0 && !$opt{soft}) {
        fail "$opt{desc}(退出码 @{[ $rc >> 8 ]})";
    }
    return ($rc == 0) ? 1 : 0;
}

sub capture_cmd {
    my ($cmd) = @_;
    my $full = join(' ', map { shell_quote($_) } @$cmd) . ' 2>/dev/null';
    my $out = `$full`;
    return defined $out ? $out : '';
}

sub is_macho {
    my ($p) = @_;
    open my $fh, '<:raw', $p or return 0;
    my $b = '';
    my $n = read $fh, $b, 4;
    close $fh;
    return 0 unless defined $n && $n == 4;
    my $hex = unpack('H8', $b);
    # cffaedfe/feedfacf = MH_MAGIC_64 小端/大端;cffaedfa/feedface = 32 位两种;cafebabe = fat
    return ($hex =~ /^(cffaedfe|cffaedfa|feedface|feedfacf|cafebabe|bebafeca)$/) ? 1 : 0;
}

# ----------------------------------------------------------------------------
# __asar_integrity 节清零(OpenAI 定制版专用)
# 该版把 asar header 哈希以内嵌形式放在 Framework 的 __DATA_CONST,__asar_integrity
# 节里(结构:32 字节标识 + 混淆哈希 + 尾部校验,共 66 字节),native 校验器
# 读取后与实际 asar header 哈希比对,内容非空且不匹配即 FATAL 秒退。
# 修改 asar 后无法按原混淆算法重算,但实测节为全零时该校验被跳过,故清零。
# 支持 fat 与单架构 Mach-O;只处理 ≤4096 字节的节;已是全零则跳过(幂等)。
# ----------------------------------------------------------------------------
sub _clear_sections_in_macho {
    my ($path) = @_;
    my $total = 0;
    open my $fh, '+<:raw', $path or return 0;
    my $hdr = '';
    return 0 unless read($fh, $hdr, 4) == 4;
    my $be = unpack('N', $hdr);
    my @slices;
    if ($be == 0xcafebabe) {            # fat binary
        my $fat = '';
        seek($fh, 4, 0);
        return 0 unless read($fh, $fat, 4) == 4;
        my $nfat = unpack('N', $fat);
        return 0 if $nfat < 1 || $nfat > 8;
        $fat = '';
        return 0 unless read($fh, $fat, 20 * $nfat) == 20 * $nfat;
        for my $i (0 .. $nfat - 1) {
            push @slices, unpack('N', substr($fat, $i * 20 + 8, 4));
        }
    }
    elsif ($be == 0xcffaedfe) {         # 单架构 MH_MAGIC_64(小端)
        push @slices, 0;
    }
    else { return 0; }

    for my $sloff (@slices) {
        seek($fh, $sloff, 0);
        my $mh = '';
        next if $sloff + 32 > -s $fh;
        next unless read($fh, $mh, 32) == 32;
        next unless unpack('V', substr($mh, 0, 4)) == 0xfeedfacf;
        my $ncmds      = unpack('V', substr($mh, 16, 4));
        my $sizeofcmds = unpack('V', substr($mh, 20, 4));
        next if $ncmds < 1 || $ncmds > 4096 || $sizeofcmds < 1 || $sizeofcmds > (1 << 20);
        my $cmds = '';
        next unless read($fh, $cmds, $sizeofcmds) == $sizeofcmds;
        my $off = 0;
        while ($off + 8 <= length($cmds)) {
            my ($cmd, $cmdsize) = unpack('V2', substr($cmds, $off, 8));
            last if $cmdsize < 8 || $off + $cmdsize > length($cmds);
            if ($cmd == 0x19) {         # LC_SEGMENT_64
                my $nsects = unpack('V', substr($cmds, $off + 64, 4));
                if ($nsects >= 0 && $nsects <= 1024) {
                    my $so = $off + 72;
                    for my $i (0 .. $nsects - 1) {
                        last if $so + 80 > length($cmds);
                        my $sectname = substr($cmds, $so, 16);
                        $sectname =~ s/\0.*$//s;
                        if ($sectname eq '__asar_integrity') {
                            my $size = unpack('Q<', substr($cmds, $so + 40, 8));
                            my $foff = unpack('V', substr($cmds, $so + 48, 4));
                            my $max = -s $fh;
                            if ($foff > 0 && $size >= 8 && $size <= 4096 && $sloff + $foff + $size <= $max) {
                                seek($fh, $sloff + $foff, 0);
                                my $cur = '';
                                if (read($fh, $cur, $size) == $size && $cur ne "\0" x $size) {
                                    seek($fh, $sloff + $foff, 0);
                                    print $fh "\0" x $size;
                                    $total++;
                                }
                            }
                        }
                        $so += 80;
                    }
                }
            }
            $off += $cmdsize;
        }
    }
    close $fh;
    return $total;
}

# 扫描副本内全部 Mach-O 并清零 __asar_integrity 节;返回 {文件=>节数}
sub clear_asar_integrity_sections {
    my ($dest) = @_;
    my %cleared;
    my @binaries;
    find({ no_chdir => 1, wanted => sub {
        return if -l $_;
        return unless -f $_;
        push @binaries, $_ if is_macho($_);
    } }, "$dest/Contents");
    for my $b (sort @binaries) {
        my $n = _clear_sections_in_macho($b);
        $cleared{$b} = $n if $n;
    }
    return \%cleared;
}

# 就地等长替换文件中的多种形态;返回替换次数(跳过符号链接)
sub replace_inplace_equal_length {
    my ($path, $map) = @_;
    return 0 if -l $path;
    my $data = slurp($path);
    my $total = 0;
    for my $old (sort { length($b) <=> length($a) } keys %$map) {
        my $new = $map->{$old};
        fail "内部错误:非等长替换请求" if length($old) != length($new);
        my $n = ($data =~ s/\Q$old\E/$new/g);
        $total += $n;
    }
    spew_raw($path, $data) if $total;
    return $total;
}

sub iso_now { return strftime('%Y-%m-%dT%H:%M:%SZ', gmtime); }

# ----------------------------------------------------------------------------
# 安装进度上报(供 GUI 轮询):键值行格式,临时文件 + rename 原子写。
#   STAGE inspect|copy|patch|integrity|sign|done|error
#   PCT   0-100(全局口径;GUI 直接显示)
#   DETAIL 一行人类可读说明
# ----------------------------------------------------------------------------
sub progress_write {
    my ($file, $stage, $pct, $detail) = @_;
    return unless defined $file && $file ne '';
    my $body = "STAGE $stage\nPCT $pct\n" . (defined $detail && $detail ne '' ? "DETAIL $detail\n" : '');
    my $tmp = "$file.tmp$$";
    open my $fh, '>:raw', $tmp or return;
    print {$fh} $body;
    close $fh;
    rename($tmp, $file);    # 原子替换,读方不会见到半行
    return 1;
}

# du -sk 千字节(目录递归);watcher 采样复制进度用
sub _du_kb {
    my ($p) = @_;
    open my $dh, '-|', '/usr/bin/du', '-sk', $p or return 0;
    my $line = <$dh>;
    close $dh;
    return (defined $line && $line =~ /^(\d+)/) ? $1 + 0 : 0;
}

# ----------------------------------------------------------------------------
# 终端进度条(SMO 品牌渐变):实心 █ 按位置绿→蓝插值,空槽暗灰实心块
# (与横幅同规范:绝不用 ▓░▒ 抖点)。仅真 TTY 渲染,\r 覆盖单行刷新。
# ----------------------------------------------------------------------------
sub _print_progress_bar {
    my ($pct, $label) = @_;
    return 0 unless -t STDOUT;
    my $width = 36;
    my $fill = int($width * $pct / 100);
    $fill = 0 if $fill < 0; $fill = $width if $fill > $width;
    my @top = (16, 217, 126);
    my @bot = (51, 102, 255);
    my $bar = '';
    my $fill_ch = _tty_utf8() ? '█' : '#';    # 非 UTF-8 终端降级为 ASCII
    for my $i (0 .. $width - 1) {
        my $t = $width > 1 ? $i / ($width - 1) : 0;
        if ($i < $fill) {
            my @rgb = map { int($top[$_] + ($bot[$_] - $top[$_]) * $t) } 0 .. 2;
            $bar .= sprintf("\e[38;2;%d;%d;%dm", @rgb) . $fill_ch;
        }
        else {
            $bar .= "\e[38;2;60;60;60m" . $fill_ch;
        }
    }
    printf("\r\e[2K SMO  %s\e[0m  %3d%%  %s", $bar, $pct, $label);
    $| = 1;
    return 1;
}

# 进度条收尾:保留已完成行或清除(仅 TTY)
sub _end_progress_bar {
    return 0 unless -t STDOUT;
    print "\e[0m\n";
    return 1;
}

# ----------------------------------------------------------------------------
# SMO 像素字横幅(纯 Perl 移植自 smo-terminal-banner 技能的 bash 版):
# 7 行 × 31 列等宽网格;纵向真彩渐变(顶 #10D97E → 底 #3366FF);
# 右下错位 1 格投影,同位置 38% 暗化色;字符统一用实心 █(不用 ▓░▒ 抖点)。
# 网格内部用单字节 '#' 占位(本文件未启用 utf8 pragma,源码按字节处理,
# 直接对多字节 '█' 做 substr 会切碎),输出时再展开为 UTF-8 实心块。
# 非 TTY(管道/重定向)时不输出,避免裸转义序列污染日志。
# ----------------------------------------------------------------------------
my @SMO_ROWS = (
    ' ######   ###     ###   ###### ',
    '##    ##  ####   ####  ##    ##',
    '##        ## ## ## ##  ##    ##',
    ' ######   ##  ###  ##  ##    ##',
    '      ##  ##   #   ##  ##    ##',
    '##    ##  ##       ##  ##    ##',
    ' ######   ##       ##   ###### ',
);
my $SMO_FILL = '█';    # 源码字节串(UTF-8 3 字节),print 原样输出

# 终端是否为 UTF-8 编码(用于决定方块字符还是 ASCII 降级;
# 部分 GUI 启动的终端不带 LANG/LC_*,此时按非 UTF-8 处理,避免乱码)
sub _tty_utf8 {
    for my $v ($ENV{LC_ALL}, $ENV{LC_CTYPE}, $ENV{LANG}) {
        next unless defined $v;
        return 1 if $v =~ /utf-?8/i;
        return 0 if $v ne '';        # 有 locale 但不含 UTF-8 → 非 UTF-8 终端
    }
    return 0;                        # 无任何 locale 信息 → 保守按非 UTF-8
}

sub smo_banner {
    my ($force) = @_;
    return 0 unless $force || -t STDOUT;    # 默认只在真实终端显示
    my $utf8  = _tty_utf8();
    my $fill  = $utf8 ? $SMO_FILL : '#';    # 非 UTF-8 终端降级为 ASCII,防乱码
    my @top = (16, 217, 126);     # #10D97E
    my @bot = (51, 102, 255);     # #3366FF
    my $out = "\n";
    for my $r (0 .. 7) {          # 第 8 行是纯投影行
        my $block = $r < 7  ? $SMO_ROWS[$r]        : '';
        my $echo  = $r >= 1 ? $SMO_ROWS[ $r - 1 ]  : '';
        my $rr = $r > 6 ? 6 : $r;
        # 与 bash 原版相同的整数中间截断(先乘后整除,向零取整),避免浮点和的 off-by-one
        my @fg = map { $top[$_] + int(($bot[$_] - $top[$_]) * $rr / 6) } 0 .. 2;
        my @sh = map { int($fg[$_] * 38 / 100) } 0 .. 2;
        my $line = '   ';
        my $prev = ' ';
        for my $c (0 .. 31) {    # 31 列网格 + 1 列:右移投影可占到第 32 列
            my $cell = ' ';
            my $bc = $c < length($block) ? substr($block, $c, 1) : '';
            my $ec = $c >= 1 && $c - 1 < length($echo) ? substr($echo, $c - 1, 1) : '';
            if    ($bc eq '#') { $cell = 'B' }
            elsif ($ec eq '#') { $cell = 'E' }
            if ($cell ne $prev) {
                if    ($cell eq 'B') { $line .= sprintf("\e[38;2;%d;%d;%dm", @fg) }
                elsif ($cell eq 'E') { $line .= sprintf("\e[38;2;%d;%d;%dm", @sh) }
                $prev = $cell;
            }
            $line .= $cell eq ' ' ? ' ' : $fill;
        }
        $out .= "$line\e[0m\n";
    }
    # ---- sanmaocloud 品牌行(UTF-8 终端中文版 / 其他终端 ASCII 版) ----
    my $GREEN = "\e[38;2;16;217;126m";
    my $GREY  = "\e[38;2;176;190;200m";
    my $DIM   = "\e[38;2;96;106;116m";
    if ($utf8) {
        my $rule = $DIM . '─' x 36 . "\e[0m";
        $out .= "  $rule\n";
        $out .= "   ${GREEN}sanmaocloud · 三猫云\e[0m\n";
        $out .= "   ${GREY}Codex 中文启动器 —— 完全离线 · 不动原版 · 随时卸载\e[0m\n";
        $out .= "  $rule\n";
    }
    else {
        my $rule = $DIM . '-' x 36 . "\e[0m";
        $out .= "  $rule\n";
        $out .= "   ${GREEN}sanmaocloud\e[0m\n";
        $out .= "   ${GREY}Codex Chinese Launcher -- offline / no original touched\e[0m\n";
        $out .= "  $rule\n";
    }
    print $out, "\n";
    return 1;
}

# ----------------------------------------------------------------------------
# 补丁内容变换(等长);返回 (新内容, 统计)
#
# V2 语义(适配 26.1027.51404+):参数替换不可行 ——
#   R2 的 f(v.localeOverride) 中 f 期望【设置键对象】(有 .key 属性),
#       传 "zh-CN" 字符串会导致运行时解引用失败;
#   R3 的 r.getEffective(k) 是设置查询,键名换成 "zh-CN" 只会查到不存在的键。
# 因此 R2/R3 一律把【整个调用表达式】替换为 "zh-CN" 字面量 + 空格填充:
#   we(ae.localeOverride)                      →  "zh-CN"␣␣␣…
#   eA.settingsStore.getEffective(el.Szl.localeOverride.key) → "zh-CN"␣␣␣…
# 表达式位置上的字符串字面量后跟空白完全合法。
# (?![.(\[=`]) 守卫:若匹配后紧跟属性访问/调用/下标/赋值/模板则跳过,
# 防止把方法链破坏成非法语法。
# ----------------------------------------------------------------------------
sub _zh_literal_pad {
    # 返回与匹配等长的 "zh-CN" 字面量 + 空格填充
    my ($match_len) = @_;
    my $lit = '"' . $LANGUAGE . '"';
    fail "语言补丁目标表达式过短,无法等长替换" if $match_len < length($lit);
    return $lit . (' ' x ($match_len - length($lit)));
}

sub patch_js {
    my ($content) = @_;
    my %st = (flag => 0, locale => 0, effective => 0);

    # R1:匹配段内 !1) → !0)(字节级等长;口径与 inspect 一致)
    # 注:外层 s///e 代码块内不能出现 "/" 定界符,故用 substr 改末段 "1" 为 "0"
    $st{flag} = ($content =~ s/($RE_FLAG_OFF)/
        my $m = $1;
        fail "语言补丁不符合等长规则" unless substr($m, -2, 1) eq '1';
        substr($m, -2, 1) = '0';
        $m /ge);

    # R3 整表达式替换:先于 R2(两者目标不重叠,顺序仅作保险)
    $st{effective} = ($content =~ s/($RE_EFFECT)(?![.(\[=`])/
        _zh_literal_pad(length($1)) /ge);

    # R2 整表达式替换
    $st{locale} = ($content =~ s/($RE_LOCALE)(?![.(\[=`])/
        _zh_literal_pad(length($1)) /ge);

    return ($content, \%st);
}

# 计算 asar integrity(hash + 块哈希;真实 asar 的键名为 blocks)
sub compute_integrity {
    my ($data) = @_;
    my @blocks;
    for (my $off = 0; $off < length($data); $off += $BLOCK_SIZE) {
        push @blocks, Digest::SHA::sha256_hex(substr($data, $off, $BLOCK_SIZE));
    }
    return { hash => Digest::SHA::sha256_hex($data), blocks => \@blocks };
}

# ----------------------------------------------------------------------------
# ASAR 解析
#   真实布局(经 ChatGPT.app / Obsidian.app 的 app.asar 实证):
#     [u32 0] = 4(字符串长度前缀占位)
#     [u32 4] = 8 + jsonLen + pad(pickle 总尺寸)
#     [u32 8] = 4 + jsonLen + pad
#     [u32 12] = jsonLen(header JSON 字节数)
#     [16 .. 16+jsonLen) = header JSON,后接 0..3 字节 0 填充至 4 倍数
#     dataStart = 16 + jsonLen + pad = 8 + u32@4
#   文件条目:packed 带 size/offset;unpacked 带 size+unpacked:true(无 offset 键)
# ----------------------------------------------------------------------------
package Asar;

sub new {
    my ($class, $path) = @_;
    open(my $fh, '<:raw', $path) or main::fail "无法打开 $path:$!";
    my $head = '';
    defined(read($fh, $head, 16)) or main::fail "读取 $path 失败:$!";
    main::fail "文件头不受支持(非 ASAR 格式):$path" if length($head) < 16;
    my $u0  = main::u32le(substr($head,  0, 4));
    my $u4  = main::u32le(substr($head,  4, 4));
    my $u8  = main::u32le(substr($head,  8, 4));
    my $len = main::u32le(substr($head, 12, 4));
    main::fail "长度或文件头无效(ASAR 头尺寸异常):$path"
        if $u0 != 4 || $len <= 0 || $len > 64 * 1024 * 1024;
    my $pad = (4 - $len % 4) % 4;
    main::fail "长度或文件头无效:$path"
        if $u4 != 8 + $len + $pad || $u8 != 4 + $len + $pad;
    seek($fh, 16, 0) or main::fail "无法定位 ASAR 头:$path";
    my $json = '';
    my $got = read($fh, $json, $len);
    main::fail "读取 ASAR 头不完整:$path" unless defined $got && $got == $len;
    my $tree = eval { JSON::PP::decode_json($json) };
    main::fail "无法解析 ASAR 资源目录:$path" if $@ || !ref $tree || ref $tree ne 'HASH';
    my $self = bless {
        path => $path, fh => $fh,
        json_len => $len, header_raw => $json,
        data_start => 16 + $len + $pad,
        tree => $tree, files => {},
    }, $class;
    $self->_walk('', $tree->{files} || {});
    return $self;
}

sub _walk {
    my ($self, $prefix, $node) = @_;
    for my $name (sort keys %{$node || {}}) {
        my $e = $node->{$name};
        my $path = $prefix eq '' ? $name : "$prefix/$name";
        if (ref $e eq 'HASH' && exists $e->{files}) {
            $self->_walk($path, $e->{files});
        }
        elsif (ref $e eq 'HASH' && exists $e->{link}) {
            next;   # asar 合法符号链接条目:不读不写,忽略
        }
        elsif (ref $e eq 'HASH' && defined $e->{size}
               && ($e->{unpacked} || defined $e->{offset})) {
            main::fail "条目尺寸无效(负值):$path" if $e->{size} < 0;
            if (!$e->{unpacked} && $e->{offset} < 0) {
                main::fail "条目偏移无效(负值):$path";
            }
            $self->{files}{$path} = {
                size      => 0 + $e->{size},
                offset    => $e->{unpacked} ? undef : (0 + $e->{offset}),
                unpacked  => $e->{unpacked} ? 1 : 0,
                integrity => $e->{integrity},
            };
        }
        else {
            main::fail "ASAR 资源目录格式无效:$path";
        }
    }
}

sub read_file_bytes {
    my ($self, $path) = @_;
    my $e = $self->{files}{$path} or main::fail "ASAR 内不存在条目:$path";
    main::fail "条目为 unpacked 外置文件:$path" if $e->{unpacked};
    my $abs = $self->{data_start} + $e->{offset};
    main::fail "资源偏移无效:$path" if $abs + $e->{size} > -s $self->{path};
    seek($self->{fh}, $abs, 0) or main::fail "资源偏移无效:$path";
    my $buf = '';
    my $n = read($self->{fh}, $buf, $e->{size});
    main::fail "读取资源不完整:$path" unless defined $n && $n == $e->{size};
    return $buf;
}

# 流式计算条目内容的 SHA-256(大文件不占双份内存);返回 hex 或 undef
sub hash_entry_streaming {
    my ($self, $path) = @_;
    my $e = $self->{files}{$path} or return undef;
    return undef if $e->{unpacked};
    seek($self->{fh}, $self->{data_start} + $e->{offset}, 0) or return undef;
    my $sha = Digest::SHA->new(256);
    my $left = $e->{size};
    while ($left > 0) {
        my $chunk = '';
        my $want = $left > 4194304 ? 4194304 : $left;
        my $n = read($self->{fh}, $chunk, $want);
        return undef unless defined $n && $n > 0;
        $sha->add($chunk);
        $left -= $n;
    }
    return $sha->hexdigest;
}

sub target_paths {
    my ($self) = @_;
    my @out;
    for my $p (sort keys %{$self->{files}}) {
        for my $pre (@main::PATCH_TARGETS) {
            if (index($p, $pre) == 0) { push @out, $p; last; }
        }
    }
    return @out;
}

sub locale_file_count {
    my ($self) = @_;
    my $n = 0;
    for my $p (keys %{$self->{files}}) {
        $n++ if $p eq $main::LOCALE_MARKER_FILE || index($p, $main::LOCALE_MARKER_PREFIX) == 0;
    }
    return $n;
}

sub has_locale_resources {
    my ($self) = @_;
    return (exists $self->{files}{$main::LOCALE_MARKER_FILE}
         && grep { index($_, $main::LOCALE_MARKER_PREFIX) == 0 } keys %{$self->{files}}) ? 1 : 0;
}

sub header_hash { my ($s) = @_; return Digest::SHA::sha256_hex($s->{header_raw}); }

sub DESTROY {
    my ($self) = @_;
    close($self->{fh}) if ref $self && $self->{fh};
}

# ----------------------------------------------------------------------------
# header 定点 integrity 更新(等长、保格式、与键序无关)
#   通过「offset 值」/「size+unpacked+旧hash」定位条目对象的括号平衡区间,
#   只在区间内替换 hash 与块数组 —— 不误伤内容相同但位置不同的其它条目,
#   兼容任意键序(真实 asar 为 size,offset,integrity;canonical 为字母序)
#   与带空格排版。返回 (新 header, 替换条目数)。
# ----------------------------------------------------------------------------
package main;

# 包含 $pos 的最内层 JSON 对象区间(条目键直接位于条目对象内,故即条目对象)
sub _entry_span {
    my ($h, $pos) = @_;
    my ($depth, $start) = (0, undef);
    for (my $i = $pos; $i >= 0; $i--) {
        my $c = substr($h, $i, 1);
        if    ($c eq '}') { $depth++; }
        elsif ($c eq '{') {
            if ($depth == 0) { $start = $i; last; }
            $depth--;
        }
    }
    return () unless defined $start;
    $depth = 0;
    for (my $i = $start; $i < length($h); $i++) {
        my $c = substr($h, $i, 1);
        if    ($c eq '{') { $depth++; }
        elsif ($c eq '}') {
            $depth--;
            return ($start, $i + 1) if $depth == 0;
        }
    }
    return undef;
}

# 在条目文本内做等长替换;返回替换计数
sub _patch_entry {
    my ($eref, $chg) = @_;
    my $cnt = 0;
    if ($$eref =~ /"hash"\s*:\s*"([0-9A-Fa-f]{64})"/i) {
        my $old = $1;
        if (lc($old) eq lc($chg->{old_hash})) {
            my $rep = $chg->{old_hash};
            (my $before = $$eref) =~ s/("hash"\s*:\s*")\Q$rep\E(")/$1$chg->{new_hash}$2/i;
            fail "语言补丁不符合等长规则(哈希)" unless length($before) == length($$eref);
            $$eref = $before;
            $cnt = 1;
        }
        elsif (lc($old) eq lc($chg->{new_hash})) {
            $cnt = 1;   # 共享条目二次处理时已替换
        }
    }
    if ($$eref =~ /"(blocks|blockSizeHashes)"\s*:\s*\[([^\]]*)\]/) {
        my ($key_name, $inner) = ($1, $2);
        my @nb = @{$chg->{new_blocks} || []};
        my $i = 0;
        (my $new_inner = $inner) =~ s/([0-9A-Fa-f]{64})/ $i <= $#nb ? $nb[$i++] : $1 /ge;
        fail "语言补丁不符合等长规则(块哈希)" unless length($new_inner) == length($inner);
        my $qi = "\Q$inner\E";
        $$eref =~ s/("\Q$key_name\E"\s*:\s*\[)$qi(\])/$1$new_inner$2/;
    }
    elsif (@{$chg->{old_blocks} || []}) {
        fail "无法定位语言补丁(块哈希数组缺失)";
    }
    return $cnt;
}

sub rewrite_header_integrity {
    my ($header, $chg_packed, $chg_unpacked) = @_;
    my $replaced = 0;

    # packed:按 offset 值(字符串或数字形态)定位所有匹配条目
    for my $key (sort keys %$chg_packed) {
        my ($off, $size) = split /:/, $key;
        my $chg = $chg_packed->{$key};
        my $pos = 0;
        while (($pos = index($header, '"offset"', $pos)) >= 0) {
            my $seg = substr($header, $pos, 100);
            if ($seg =~ /^"offset"\s*:\s*"?(\d+)"?/ && $1 == $off) {
                my @span = _entry_span($header, $pos);
                if (@span) {
                    my ($s, $e) = @span;
                    my $entry = substr($header, $s, $e - $s);
                    if ($entry =~ /"size"\s*:\s*(\d+)/ && $1 == $size) {
                        $replaced += _patch_entry(\$entry, $chg);
                        substr($header, $s, $e - $s) = $entry;
                    }
                }
            }
            $pos += 8;
        }
    }
    # unpacked:按 size + unpacked:true + 旧hash 三重验证
    for my $chg (@$chg_unpacked) {
        my $pos = 0;
        while (($pos = index($header, '"size"', $pos)) >= 0) {
            my $seg = substr($header, $pos, 60);
            if ($seg =~ /^"size"\s*:\s*(\d+)[,}\s]/ && $1 == $chg->{size}) {
                my @span = _entry_span($header, $pos);
                if (@span) {
                    my ($s, $e) = @span;
                    my $entry = substr($header, $s, $e - $s);
                    if ($entry =~ /"unpacked"\s*:\s*true/
                        && $entry =~ /"hash"\s*:\s*"([0-9A-Fa-f]{64})"/i
                        && lc($1) eq lc($chg->{old_hash})) {
                        $replaced += _patch_entry(\$entry, $chg);
                        substr($header, $s, $e - $s) = $entry;
                    }
                }
            }
            $pos += 6;
        }
    }
    return ($header, $replaced);
}

# ----------------------------------------------------------------------------
# plist 工具
# ----------------------------------------------------------------------------
sub plist_value {
    my ($plist, $key) = @_;
    my $v = capture_cmd(['/usr/bin/plutil', '-extract', $key, 'raw', '-o', '-', $plist]);
    $v =~ s/\s+$//;
    return $v;
}

sub _bundle_id_of {
    my ($plist) = @_;
    return '' unless -f $plist;
    my $v = plist_value($plist, 'CFBundleIdentifier') // '';
    return $v;
}

# 自动发现 Codex 桌面版:应用名可能是 Codex.app 或 ChatGPT.app(bundle id 都是
# com.openai.codex),依次查固定候选 → Spotlight → 扫描应用文件夹
sub find_codex_app {
    my @candidates;
    push @candidates, ($ENV{HOME} . '/Applications/ChatGPT.app', $ENV{HOME} . '/Applications/Codex.app')
        if $ENV{HOME};
    push @candidates, '/Applications/ChatGPT.app', '/Applications/Codex.app';
    for my $c (@candidates) {
        next unless -d $c;
        return $c if _bundle_id_of("$c/$PLIST_REL") eq $BUNDLE_ID;
    }
    my $mdf = capture_cmd(['/usr/bin/mdfind', "kMDItemCFBundleIdentifier == '$BUNDLE_ID'"]);
    for my $l (split /\n/, $mdf) {
        $l =~ s/\s+$//;
        next unless $l =~ /\.app$/ && -d $l;
        return $l if _bundle_id_of("$l/$PLIST_REL") eq $BUNDLE_ID;
    }
    for my $dir ('/Applications', ($ENV{HOME} // '') . '/Applications') {
        next unless opendir(my $dh, $dir);
        my @apps = grep { /\.app$/ } readdir($dh);
        closedir($dh);
        for my $e (@apps) {
            my $p = "$dir/$e";
            next unless -d $p;
            return $p if _bundle_id_of("$p/$PLIST_REL") eq $BUNDLE_ID;
        }
    }
    return undef;
}

sub app_info {
    my ($app) = @_;
    fail "无法读取应用目录:$app" unless -d $app;
    my $plist = "$app/$PLIST_REL";
    fail "无法读取应用目录(缺少 Info.plist):$app" unless -f $plist;
    fail "Info.plist 是符号链接,已停止:$plist" if -l $plist;
    my $bid = plist_value($plist, 'CFBundleIdentifier') // '';
    fail "所选应用不是 Codex(需要 Bundle ID $BUNDLE_ID,实际为 '$bid')" unless $bid eq $BUNDLE_ID;
    my $ver = plist_value($plist, 'CFBundleShortVersionString');
    $ver = '?' unless defined $ver && $ver ne '';
    return ($plist, $ver);
}

sub plist_as_xml {
    my ($plist) = @_;
    my $tmp = File::Spec->tmpdir() . "/codex-zh-plist-$$-" . int(rand(1e9)) . ".xml";
    my $rc = system(join(' ', map { shell_quote($_) } ('/usr/bin/plutil', '-convert', 'xml1', '-o', $tmp, $plist)) . ' 2>/dev/null');
    return undef if $rc != 0 || !-f $tmp;
    my $xml = slurp($tmp);
    unlink $tmp;
    return $xml;
}

# ElectronAsarIntegrity 键内任意 64 位 hex(键不存在时返回 undef,不误抓其它键)
sub plist_asar_hash {
    my ($plist) = @_;
    return undef unless -f $plist;
    my $xml = plist_as_xml($plist);
    return undef unless defined $xml;
    return undef unless $xml =~ /<key>ElectronAsarIntegrity<\/key>/;
    # 键之后到 </dict>(含嵌套 Resources/app.asar 子字典)整段内取 hex
    my ($sec) = $xml =~ /<key>ElectronAsarIntegrity<\/key>\s*<dict>(.*?)<\/dict>/s;
    return undef unless defined $sec;
    my ($h) = $sec =~ />([0-9A-Fa-f]{64})</;
    return $h;
}

sub _prefix_bytes {
    my ($path, $len, $skip) = @_;
    $skip //= 0;
    open my $fh, '<:raw', $path or fail "无法读取 $path:$!";
    seek($fh, $skip, 0);
    my $buf = '';
    defined(read($fh, $buf, $len - $skip)) or fail "读取 $path 不完整";
    close $fh;
    return $buf;
}

# ----------------------------------------------------------------------------
# inspect(只读检测)
# ----------------------------------------------------------------------------
sub do_inspect {
    my ($app, $quiet) = @_;
    my ($plist, $ver) = app_info($app);
    my $asar_path = "$app/$ASAR_REL";
    fail "缺少 app.asar:$asar_path" unless -f $asar_path;

    my $asar = Asar->new($asar_path);
    my $src_hash = $asar->header_hash();
    my %report = (
        appPath => $app, appVersion => $ver,
        localeFileCount => $asar->locale_file_count(),
        sourceHeaderHash => $src_hash,
    );

    my ($compat, $why) = (1, '');
    if (!$asar->has_locale_resources()) {
        $compat = 0;
        $why = '此版本未携带完整的本地中文资源,无法离线汉化。请使用包含中文资源的官方 Mac 版。';
    }

    # ElectronAsarIntegrity 口径识别(json = SHA256(header JSON 字节区,Electron 官方)
    my $plist_hash = plist_asar_hash($plist);
    $report{headerHashBasis} = 'absent';
    if (defined $plist_hash) {
        my $h_json  = $src_hash;
        my $h_all   = Digest::SHA::sha256_hex(_prefix_bytes($asar_path, $asar->{data_start}));
        my $h_from4 = Digest::SHA::sha256_hex(_prefix_bytes($asar_path, $asar->{data_start}, 4));
        my $basis;
        $basis = 'json'  if lc($plist_hash) eq lc($h_json);
        $basis = 'full'  if !$basis && lc($plist_hash) eq lc($h_all);
        $basis = 'from4' if !$basis && lc($plist_hash) eq lc($h_from4);
        $report{headerHashBasis} = $basis // 'mismatch';
        if (!defined $basis) {
            $compat = 0;
            $why = '应用的 ASAR 文件头与 Info.plist 完整性记录不一致。';
        }
    }

    # 补丁点检测
    my ($already, $hits, @will_patch) = (0, 0);
    for my $p ($asar->target_paths()) {
        my $e = $asar->{files}{$p};
        my $c;
        if ($e->{unpacked}) {
            my $up = "$app/" . dirname($ASAR_REL) . "/app.asar.unpacked/$p";
            next unless -f $up && !-l $up;
            $c = slurp($up);
        }
        else {
            $c = eval { $asar->read_file_bytes($p) };
            next if $@;
        }
        my $f  = () = ($c =~ /$RE_FLAG_OFF/g);
        my $l  = () = ($c =~ /$RE_LOCALE/g);
        my $e2 = () = ($c =~ /$RE_EFFECT/g);
        my $on = () = ($c =~ /$RE_FLAG_ON/g);
        $hits += $f + $l + $e2;
        $already = 1 if $on && !$f;
        push @will_patch, $p if $f || $l || $e2;
    }
    if ($hits == 0 && !$already) {
        $compat = 0;
        $why ||= '当前版本的语言代码与补丁不兼容,已停止(语言开关 / 界面语言 / 菜单语言相关代码未找到)。';
    }

    $report{alreadyEnabled} = $already ? 1 : 0;
    $report{patchFiles} = \@will_patch;
    $report{compatible} = $compat;
    $report{reason} = $why if $why ne '';

    unless ($quiet) {
        info "应用:$app";
        info "版本:$ver";
        info "中文资源文件:$report{localeFileCount} 个";
        info "需调整的文件:" . (@will_patch ? join(', ', @will_patch) : '(无)');
        info "已启用中文:" . ($already ? '是' : '否');
        info "检测完成:" . ($compat ? '可创建中文版应用。' : "无法汉化 —— $why");
    }
    return \%report;
}

# ----------------------------------------------------------------------------
# install
# ----------------------------------------------------------------------------
sub do_install {
    my ($app, $dest, $progfile) = @_;
    progress_write($progfile, 'inspect', 2, '正在检测官方 Codex 应用……');
    my $report = do_inspect($app, 1);
    fail($report->{reason} || '检测不通过,无法安装。') unless $report->{compatible};
    if (-e $dest) {
        # 已存在:若是本工具的成品,直接指路;否则要求先清理
        my $old_manifest = "$dest/Contents/Resources/$MANIFEST_NAME";
        my $m = eval { JSON::PP::decode_json(slurp($old_manifest)) };
        if (!$@ && ref $m && ($m->{language} // '') eq $LANGUAGE) {
            my $when = $m->{installedAt} // '';
            fail "中文版已安装过($when),无需重复安装。\n直接打开使用:$dest\n(首次打开如提示“无法验证/已损坏”:右键点它选“打开”。)\n如需重新安装,请先运行『卸载汉化』删除旧副本。";
        }
        fail "安装目标必须是不存在的 .app 路径。请先卸载旧副本,或选择新的位置。:$dest";
    }

    my $parent = dirname($dest);
    unless (-d $parent) {
        require File::Path;
        File::Path::make_path($parent);
        info "已创建目录:$parent";
    }

    info "复制官方应用到新的中文版副本……";
    progress_write($progfile, 'copy', 3, '正在复制官方应用(约 1-2 分钟,无需联网)……');
    # 复制阶段无原生进度:fork 采样器按目标体积估算(ditto 期间持续上报)
    my $watcher_pid = fork();
    if (!defined $watcher_pid) {
        warn "fork 进度采样器失败(忽略,不影响安装)\n";
    }
    elsif ($watcher_pid == 0) {
        # ---- 子进程:采样循环,父进程结束或 ditto 完成后由父 kill ----
        my $src_kb = _du_kb($app);
        while (1) {
            last if kill(0, getppid()) == 0;    # 父进程已退出
            my $dst_kb = _du_kb($dest);
            my $pct = ($src_kb > 0) ? int($dst_kb * 100 / $src_kb) : 0;
            $pct = 0 if $pct < 0;
            $pct = 99 if $pct > 99;
            progress_write($progfile, 'copy', 3 + int($pct * 0.75),
                "正在复制官方应用…… $pct%");
            _print_progress_bar($pct, "正在复制官方应用(约 1-2 分钟,无需联网)……");
            sleep 1;
        }
        POSIX::_exit(0);    # 绕过 END/DESTROY
    }
    my $copy_ok = eval { run_cmd(['/usr/bin/ditto', $app, $dest], desc => '复制官方应用'); 1 };
    if ($watcher_pid) {
        kill('KILL', $watcher_pid);
        waitpid($watcher_pid, 0);
        _end_progress_bar();
    }
    die "复制官方应用失败:$@" unless $copy_ok;
    fail "安装目标已被其他程序创建,已停止。" unless -f "$dest/$ASAR_REL";

    # 源一致性(复制期间源未变化)
    fail "源应用在复制时已发生变化,请重试。"
        if Asar->new("$app/$ASAR_REL")->header_hash() ne $report->{sourceHeaderHash};

    # 失败清理:无 manifest 的半成品不可信,直接移除;有 manifest 可走卸载
    my $manifest_path = "$dest/Contents/Resources/$MANIFEST_NAME";
    my $install_error = eval {
        _install_body($app, $dest, $report, $manifest_path, $progfile);
        1;
    };
    if (!$install_error) {
        my $err = $@ || '未知错误';
        if (-d $dest && !-f $manifest_path) {
            info "安装未完成,正在清理半成品副本……";
            require File::Path;
            File::Path::remove_tree($dest);
            unlink("$dest/$ASAR_REL$STAGE_SUFFIX");
            die $err;
        }
        if (-d $dest) {
            $err =~ s/\s*$/\n/;
            die "$err提示:可双击『卸载汉化.command』删除未完成的副本后再重试。\n";
        }
        die $err;
    }
    progress_write($progfile, 'done', 100, "安装完成:$dest");
    return 1;
}

sub _install_body {
    my ($app, $dest, $report, $manifest_path, $progfile) = @_;
    my ($plist, $ver) = app_info($dest);
    my $src_header_hash = $report->{sourceHeaderHash};
    my $asar_path = "$dest/$ASAR_REL";
    fail "应用包含指向外部文件的符号链接,已停止以保护原文件:$asar_path" if -l $asar_path;
    my $asar = Asar->new($asar_path);
    fail "源应用在复制时已发生变化,请重试。" if $asar->header_hash() ne $src_header_hash;

    # ---- 计算全部补丁(packed 与 unpacked 分别处理) ----
    my (%chg_packed, @chg_unpacked, @packed_writes, @unpacked_writes, @patch_names);
    my %stats = (flag => 0, locale => 0, effective => 0);
    for my $p ($asar->target_paths()) {
        my $e = $asar->{files}{$p};
        my ($old, $write_path);
        if ($e->{unpacked}) {
            $write_path = "$dest/" . dirname($ASAR_REL) . "/app.asar.unpacked/$p";
            next unless -f $write_path && !-l $write_path;
            $old = slurp($write_path);
        }
        else {
            $old = $asar->read_file_bytes($p);
        }
        my ($new, $st) = patch_js($old);
        $stats{$_} += $st->{$_} for keys %stats;
        next if $new eq $old;
        fail "补丁改变了资源长度:$p" unless length($new) == length($old);

        my $old_int = $e->{integrity};
        fail "补丁资源缺少完整性信息:$p" unless $old_int && defined $old_int->{hash};
        my $old_blocks = $old_int->{blocks};
        $old_blocks = $old_int->{blockSizeHashes} if !defined $old_blocks && defined $old_int->{blockSizeHashes};
        my $new_int  = compute_integrity($new);
        my $chg = {
            old_hash => $old_int->{hash}, new_hash => $new_int->{hash},
            old_blocks => $old_blocks || [], new_blocks => $new_int->{blocks},
        };
        push @patch_names, $p;
        if ($e->{unpacked}) {
            $chg->{size} = $e->{size};
            push @chg_unpacked, $chg;
            push @unpacked_writes, { path => $p, new => $new, file => $write_path };
        }
        else {
            $chg_packed{"$e->{offset}:$e->{size}"} = $chg;
            push @packed_writes, { path => $p, new => $new };
        }
    }
    my $total_repl = $stats{flag} + $stats{locale} + $stats{effective};
    fail "无法定位语言补丁。" unless $total_repl || $report->{alreadyEnabled};
    info "语言补丁点:开关 x$stats{flag},界面语言 x$stats{locale},生效语言 x$stats{effective}";
    progress_write($progfile, 'patch', 80, "正在应用中文补丁(共 " . scalar(@packed_writes) . " 个文件)……");

    # ---- 就地等长改写 header + 数据区(暂存文件 → 原子替换) ----
    my $stage = "$asar_path$STAGE_SUFFIX";
    my $mode = (stat($asar_path))[2] & 07777;
    copy($asar_path, $stage) or fail "无法创建中文版资源:$!";
    chmod($mode, $stage) or fail "无法设置暂存文件权限:$!";
    open my $sfh, '+<:raw', $stage or fail "无法创建中文版资源:$stage";
    if (%chg_packed || @chg_unpacked) {
        my ($header, $replaced) = rewrite_header_integrity($asar->{header_raw}, \%chg_packed, \@chg_unpacked);
        fail "中文版资源文件头验证失败(未定位到任何 integrity 条目)" unless $replaced;
        fail "补丁改变了资源长度(ASAR 头)" unless length($header) == $asar->{json_len};
        eval { JSON::PP::decode_json($header) };
        fail "中文版资源文件头验证失败(替换后 JSON 不合法)" if $@;
        seek($sfh, 16, 0) or fail "无法写入暂存文件";
        print {$sfh} $header;
        info "已同步 $replaced 条资源的完整性记录。";
    }
    for my $w (@packed_writes) {
        my $e = $asar->{files}{$w->{path}};
        seek($sfh, $asar->{data_start} + $e->{offset}, 0) or fail "资源偏移无效:$w->{path}";
        print {$sfh} $w->{new};
    }
    close $sfh or fail "无法写入暂存文件:$!";
    rename($stage, $asar_path) or fail "无法提交暂存文件:$!";
    for my $w (@unpacked_writes) {
        spew_raw($w->{file}, $w->{new});
    }
    info "锁定本地中文界面和菜单,重新计算资源完整性……";
    progress_write($progfile, 'integrity', 92, '正在同步资源完整性记录……');

    # ---- 复验(修改集内必须一致;集外如与原装记录不符仅提示) ----
    my $new_asar = Asar->new($asar_path);
    fail "补丁改变了资源长度" unless $new_asar->{json_len} == $asar->{json_len};
    for my $w (@packed_writes) {
        my $now = $new_asar->read_file_bytes($w->{path});
        fail "中文版资源内容验证失败:$w->{path}" unless $now eq $w->{new};
    }
    for my $w (@unpacked_writes) {
        fail "中文版资源内容验证失败:$w->{path}" unless slurp($w->{file}) eq $w->{new};
    }
    _verify_all_integrity($new_asar, \%chg_packed, $dest);
    my $new_header_hash = $new_asar->header_hash();

    # ---- Info.plist 完整性记录:按识别到的口径写回(等长 hex 替换) ----
    my $basis = $report->{headerHashBasis};
    my $old_plist_hash = plist_asar_hash($plist);
    if (defined $old_plist_hash && $basis =~ /^(json|full|from4)$/) {
        my $new_by_basis = _header_hash_by_basis($basis, $asar_path, $new_asar);
        if (lc($old_plist_hash) ne lc($new_by_basis)) {
            my $xml = plist_as_xml($plist);
            if (defined $xml) {
                my $cnt = $xml =~ s/([0-9A-Fa-f]{64})/lc($1) eq lc($old_plist_hash) ? $new_by_basis : $1/ge;
                if ($cnt) {
                    spew_raw($plist, $xml);
                    info "已按 $basis 口径更新 Info.plist 的 ElectronAsarIntegrity 记录。";
                }
            }
        }
    }

    # ---- 内嵌摘要槽同步(等长,best-effort;口径与 plist 一致) ----
    my $slot_old = _header_hash_by_basis($basis =~ /^(json|full|from4)$/ ? $basis : 'json', "$app/$ASAR_REL", undef, $report);
    my $slot_new = _header_hash_by_basis($basis =~ /^(json|full|from4)$/ ? $basis : 'json', $asar_path, $new_asar);
    my $slot_map = {
        lc($slot_old) => lc($slot_new),
        uc($slot_old) => uc($slot_new),
        pack('H*', $slot_old) => pack('H*', $slot_new),
    };
    my @slots;
    {
        my @binaries;
        find({ no_chdir => 1, wanted => sub {
            return if -l $_;          # 不跟随符号链接
            return unless -f $_;
            return if -s $_ > 512 * 1024 * 1024;
            push @binaries, $_ if is_macho($_);
        } }, "$dest/Contents");
        for my $b (sort @binaries) {
            my $n = replace_inplace_equal_length($b, $slot_map);
            push @slots, basename($b) if $n;
        }
    }
    info "已同步内嵌完整性摘要:" . (@slots ? join(', ', @slots) : '未发现内嵌摘要槽(可忽略)');

    # ---- 禁用 Framework 内嵌的 __asar_integrity 资源校验节 ----
    # (OpenAI 定制版用该节内嵌 asar 哈希,native 校验不匹配即 FATAL;清零即跳过)
    my $cleared_sec = clear_asar_integrity_sections($dest);
    if (%$cleared_sec) {
        info "已禁用内嵌资源校验节(__asar_integrity):"
            . join(', ', map { basename($_) . '(x' . $cleared_sec->{$_} . ')' } sort keys %$cleared_sec);
    }
    else {
        info "未发现内嵌资源校验节(可忽略)。";
    }

    # ---- manifest ----
    my $manifest = {
        schemaVersion    => 1,
        sourcePath       => $app,
        sourceVersion    => $ver,
        destination      => $dest,
        language         => $LANGUAGE,
        installedAt      => iso_now(),
        appVersion       => $report->{appVersion},
        localeFileCount  => $report->{localeFileCount},
        alreadyEnabled   => $report->{alreadyEnabled} ? 1 : 0,
        sourceHeaderHash => $src_header_hash,
        asarHeaderHash   => $new_header_hash,
        patchFiles       => [@patch_names],
    };
    spew_raw($manifest_path, JSON::PP->new->canonical(1)->pretty(1)->encode($manifest));

    # ---- 本地重签名 ----
    info "正在为中文版副本生成本地签名(无需联网)……";
    progress_write($progfile, 'sign', 96, '正在生成本地签名(无需联网)……');
    fail "无法为中文版副本生成本地签名(codesign 失败)。" unless resign_app($app, $dest);

    run_cmd(['/usr/bin/xattr', '-dr', 'com.apple.quarantine', $dest], soft => 1);

    print "\n安装完成。\n中文版应用:$dest\n补丁文件:" . join(', ', @patch_names) . "\n界面语言 / 菜单语言:$LANGUAGE\n";
    return 1;
}

# 按口径计算 header 哈希:json=SHA256(JSON 字节区);full=[0,dataStart);from4=[4,dataStart)
sub _header_hash_by_basis {
    my ($basis, $asar_path, $asar_obj, $report) = @_;
    if ($basis eq 'json') {
        return defined $asar_obj ? $asar_obj->header_hash() : ($report ? $report->{sourceHeaderHash} : undef);
    }
    my $obj = $asar_obj || Asar->new($asar_path);
    return Digest::SHA::sha256_hex(_prefix_bytes($asar_path, $obj->{data_start}, $basis eq 'from4' ? 4 : 0));
}

# 全条目完整性复验:修改集内(按 offset+size)不一致即失败;集外不一致仅提示
sub _verify_all_integrity {
    my ($new_asar, $chg_packed, $dest) = @_;
    my (@warned, %seen);
    for my $p (sort keys %{$new_asar->{files}}) {
        my $e = $new_asar->{files}{$p};
        next if $e->{unpacked} || !defined $e->{offset};
        my $key = "$e->{offset}:$e->{size}";
        next if $seen{$key}++;   # 共享同一数据区的条目只验一次
        my $int = $e->{integrity};
        next unless $int && defined $int->{hash};
        my $calc = $new_asar->hash_entry_streaming($p);
        next unless defined $calc;
        if (lc($calc) ne lc($int->{hash})) {
            fail "资源完整性校验失败:$p" if exists $chg_packed->{$key};
            push @warned, $p;
        }
    }
    if (@warned) {
        my $show = @warned > 5 ? (join(', ', @warned[0..4]) . ' 等') : join(', ', @warned);
        info "提示:以下条目的原装完整性记录与内容本就不符(未修改,不影响使用):$show";
    }
    return 1;
}

# ----------------------------------------------------------------------------
# 签名
# ----------------------------------------------------------------------------
# 注意:绝不携带 entitlements。原版 entitlements 含受限条目
# (com.apple.application-identifier / keychain-access-groups /
#  application-groups / aps-environment 等),需要真实开发者证书才允许持有;
# ad-hoc 签名带这些会被 AMFI 以 -424 "adhoc signed but contains restricted
# entitlements" 拒绝,内核直接 SIGKILL(应用秒退、无崩溃报告)。
# V37 补丁在同机的可用策略正是 codesign --force --sign -,不带 entitlements。
sub resign_app {
    my ($src_app, $dest) = @_;
    my $ok = eval {
        my @bundles;
        find({ no_chdir => 1, wanted => sub {
            return if -l $File::Find::name;
            push @bundles, $File::Find::name
                if -d $File::Find::name
                && $File::Find::name =~ /\.(framework|xpc|app|appex|bundle|plugin)$/;
        } }, "$dest/Contents");
        for my $b (sort { length($b) <=> length($a) } @bundles) {   # 嵌套深者先签
            unless (run_cmd(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', $b], soft => 1)) {
                _print_codesign_error($b);
                die "签名失败:$b\n";
            }
        }
        unless (run_cmd(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', $dest], soft => 1)) {
            _print_codesign_error($dest);
            die "签名失败:$dest\n";
        }
        1;
    };
    return 0 unless $ok;
    return run_cmd(['/usr/bin/codesign', '--verify', '--strict', '--verbose=1', $dest], soft => 1);
}

sub _print_codesign_error {
    my ($target) = @_;
    my $out = capture_cmd(['/usr/bin/codesign', '--verify', '--strict', '--verbose=2', $target]);
    print "[codex-zh] codesign 诊断:$target\n$out\n";
}

# ----------------------------------------------------------------------------
# uninstall
# ----------------------------------------------------------------------------
sub do_uninstall {
    my ($app) = @_;
    fail "此路径不是本工具生成的中文版副本,拒绝删除。:$app" unless -d $app;
    my $manifest_path = "$app/Contents/Resources/$MANIFEST_NAME";
    fail "此路径不是本工具生成的中文版副本,拒绝删除。(缺少安装清单)" unless -f $manifest_path;
    my $m = eval { JSON::PP::decode_json(slurp($manifest_path)) };
    fail "安装清单无效,拒绝自动卸载。:$manifest_path" if $@ || !ref $m;

    my $asar_path = "$app/$ASAR_REL";
    fail "此副本缺少 app.asar,拒绝自动卸载。" unless -f $asar_path;
    my $cur = Asar->new($asar_path)->header_hash();
    fail "此副本的资源已在安装后发生变化,拒绝自动卸载。可在 Finder 中自行将确认过的副本移到废纸篓。"
        unless defined $m->{asarHeaderHash} && lc($cur) eq lc($m->{asarHeaderHash});

    info "正在通过 Finder 将中文版副本移入废纸篓……";
    my $as_app = $app;
    $as_app =~ s/\\/\\\\/g;
    $as_app =~ s/"/\\"/g;
    my $rc = system('/usr/bin/osascript', '-e',
        'tell application "Finder" to delete POSIX file "' . $as_app . '"');
    fail "移入废纸篓失败(退出码 @{[ $rc >> 8 ]})。" if $rc != 0;
    print "已移除:$app\n打开原应用即可恢复原语言;聊天记录和配置未修改。\n";
    return 1;
}

# ----------------------------------------------------------------------------
# selftest:合成 Codex.app 端到端验证
# ----------------------------------------------------------------------------
# 组装最小 asar(真实四段 u32 头;unpacked 条目实体写到 $unpacked_dir)
sub _build_asar {
    my ($files_aref, $unpacked_dir, $spaced) = @_;
    my %tree;
    my $data = '';
    for my $f (@$files_aref) {
        my ($path, $content, $unpacked) = @$f;
        my @parts = split m{/}, $path;
        my $node = \%tree;
        while (@parts > 1) {
            my $d = shift @parts;
            $node->{$d} ||= { files => {} };
            $node = $node->{$d}{files};
        }
        my $int = compute_integrity($content);
        if ($unpacked) {
            $node->{$parts[0]} = { size => length($content), unpacked => JSON::PP::true, integrity => { %$int } };
            my $full = "$unpacked_dir/$path";
            require File::Path;
            File::Path::make_path(dirname($full));
            spew_raw($full, $content);
        }
        else {
            $node->{$parts[0]} = { size => length($content), offset => length($data), integrity => { %$int } };
            $data .= $content;
        }
    }
    my $json = JSON::PP->new->canonical(1)->encode({ files => \%tree });
    $json =~ s/:/: /g if $spaced;   # 带空格排版变体
    my $json_len = length $json;
    my $pad = (4 - $json_len % 4) % 4;
    my $bytes = pack('VVVV', 4, 8 + $json_len + $pad, 4 + $json_len + $pad, $json_len)
              . $json . ("\0" x $pad) . $data;
    return ($bytes, $json);
}

sub _mk_app_skeleton {
    my ($src) = @_;
    require File::Path;
    File::Path::make_path("$src/Contents/MacOS", "$src/Contents/Resources", "$src/Contents/Frameworks");
    copy('/bin/ls', "$src/Contents/MacOS/Codex") or fail "selftest: 无法复制 /bin/ls";
}

sub _write_plist {
    my ($src, $integrity_hash) = @_;
    my $extra = defined $integrity_hash ? "<key>ElectronAsarIntegrity</key>\n    <dict>\n        <key>hash</key><string>$integrity_hash</string>\n    </dict>" : '';
    spew_raw("$src/$PLIST_REL", <<"EOPL");
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.openai.codex</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>Codex</string>
    <key>CFBundleName</key><string>Codex</string>
    <key>CFBundleShortVersionString</key><string>0.42.0</string>
    <key>CFBundleVersion</key><string>0.42.0</string>
    $extra
</dict>
</plist>
EOPL
}

sub do_selftest {
    my ($keep) = @_;
    require File::Path;
    require File::Temp;
    my $tmp = File::Temp::mkdtemp('/tmp/codex-zh-selftest-XXXXXX');
    my ($npass, $nfail) = (0, 0);
    my $check = sub {
        my ($name, $cond, $detail) = @_;
        if ($cond) { $npass++; print "  PASS  $name\n"; }
        else       { $nfail++; print "  FAIL  $name" . (defined $detail && $detail ne '' ? " —— $detail" : '') . "\n"; }
        return $cond ? 1 : 0;
    };

    my $main_js = <<'EOJS';
const cfg=new Map([["theme","dark"]]);
function localeOf(u){return resolve(u.localeOverride)}
function effectiveLocale(s,u){return s.getEffective(u.localeOverride.key)}
const flags=new FeatureFlags();const i18n=flags?.get(`enable_i18n`,!1);
const menu=tr(x.localeOverride);const m2=tt.yy(x.localeOverride);
const tricky=t.localeOverride.key.getEffective(t.localeOverride.key);
const other=/localeOverride/.test("u.localeOverride");const noise="a.localeOverride";
console.log(cfg,localeOf,effectiveLocale,i18n,menu,m2,tricky,other,noise);
EOJS
    my $initial_js = 'init((v)=>render(v.localeOverride));const q=n.getEffective(n.localeOverride.key);';
    # 新版(26.x)真实形态:early-bootstrap chunk / initialize-app-host-services / general-settings
    my $bootstrap_js = 'let i=s2(e.getEffective(el.Szl.localeOverride.key))??s2(t)??"en";'
        . 'let eO=eA.settingsStore.getEffective(el.Szl.localeOverride.key);'
        . 'ex.add(eA.settingsStore.onDidChange(el.Szl.localeOverride.key,()=>{});';
    my $init_hosts_js = 'let c=s?.get(`enable_i18n`,!1);let u=s?.get(`locale_source`,`IDE`);'
        . 'function yw(e){let r=we(ae.localeOverride);return r}';
    my $gen_settings_js = 'let r=Kt(`72216192`)?.get(`enable_i18n`,!0);let c=P(w.localeOverride);';
    # V2 守卫:后随 .、( 的调用不替换(防破坏方法链/调用语法)
    my $guard_js = 'const g=fn(u.localeOverride).key;const h=fn(u.localeOverride)(x);const k=fn(u.localeOverride);';

    print "== 单元测试:patch_js(V2 整表达式替换)==\n";
    {
        my ($pj, $st) = patch_js($main_js);
        $check->('patch_js: 等长', length($pj) == length($main_js));
        $check->('patch_js: R1 命中 1', $st->{flag} == 1);
        $check->('patch_js: R2 命中 3', $st->{locale} == 3);
        $check->('patch_js: R3 命中 2', $st->{effective} == 2);
        $check->('patch_js: trick 场景整表达式替换', $pj =~ /const tricky="zh-CN" +;/);
        $check->('patch_js: R2 整表达式替换(resolve)', $pj =~ /return "zh-CN" +\}/);
    }
    {
        my ($pj, $st) = patch_js($guard_js);
        $check->('patch_js: 守卫拦截 .key 链与紧跟调用', $st->{locale} == 1 && $pj =~ /fn\(u\.localeOverride\)\.key/ && $pj =~ /fn\(u\.localeOverride\)\(x\)/);
        $check->('patch_js: 守卫未拦截普通调用', $pj =~ /k="zh-CN" +;/);
    }
    {
        my ($pj, $st) = patch_js($bootstrap_js . $init_hosts_js . $gen_settings_js);
        $check->('patch_js: 新版 bootstrap getEffective 整段替换', $pj =~ /s2\("zh-CN" +\)/ && $pj =~ /="zh-CN" +;/);
        $check->('patch_js: onDidChange 监听不被误伤', $pj =~ /onDidChange\(el\.Szl\.localeOverride\.key,/);
        $check->('patch_js: we/P 调用整段替换', $pj =~ /r="zh-CN" +;/ && $pj =~ /c="zh-CN" +;/);
    }

    print "== 单元测试:__asar_integrity 节清零 ==\n";
    {
        # 构造最小单架构 Mach-O:LC_SEGMENT_64(__DATA_CONST) + __asar_integrity 节(66 字节非零)
        my $sect_off = 184; my $sect_size = 66;
        my $mk_macho = sub {
            my $secname  = pack('a16', '__asar_integrity') . pack('a16', '__DATA_CONST');
            my $section  = $secname . pack('Q<Q<VV', 0, $sect_size, $sect_off, 0)   # addr,size,offset,align
                         . pack('V6', 0, 0, 0, 0, 0, 0);    # reloff,nreloc,flags,r1,r2,r3 → 共 80 字节
            my $segname  = pack('a16', '__DATA_CONST');
            my $cmd      = pack('VV', 0x19, 72 + 80) . $segname
                         . pack('Q<Q<Q<Q<VVVV', 0, $sect_size, $sect_off, $sect_size, 7, 3, 1, 0)
                         . $section;
            return pack('V', 0xfeedfacf) . pack('V', 0x0100000c) . pack('V', 0)
                 . pack('V', 6) . pack('V', 1) . pack('V', length($cmd))
                 . pack('V', 0) . pack('V', 0) . $cmd . ('A' x $sect_size);
        };
        my $macho = $mk_macho->();
        $check->('构造的 Mach-O 长度自洽', length($macho) == $sect_off + $sect_size);
        my $tf = "$tmp/mini.macho";
        spew_raw($tf, $macho);
        my $n1 = _clear_sections_in_macho($tf);
        my $zeroed = slurp($tf);
        $check->('清零:命中 1 节', $n1 == 1);
        $check->('清零:节区全零且文件等长', substr($zeroed, $sect_off) eq ("\0" x $sect_size) && length($zeroed) == length($macho));
        $check->('清零:幂等(再跑命中 0)', _clear_sections_in_macho($tf) == 0);
        my $nosec = $macho;
        substr($nosec, 104, 16) = pack('a16', '__other_sect');
        spew_raw("$tmp/nosec.macho", $nosec);
        $check->('清零:无目标节返回 0', _clear_sections_in_macho("$tmp/nosec.macho") == 0);
        spew_raw("$tmp/plain.bin", 'not a macho');
        $check->('清零:非 Mach-O 返回 0', _clear_sections_in_macho("$tmp/plain.bin") == 0);
        # fat 双切片(Intel 机器上的 universal binary 形态):两个 slice 的节都要清
        my ($s1, $s2) = ($mk_macho->(), $mk_macho->());
        my $fat = pack('N', 0xcafebabe) . pack('N', 2)
                . pack('N5', 0x0100000c, 0, 48, length($s1), 0)
                . pack('N5', 0x01000007, 0, 48 + length($s1), length($s2), 0)
                . $s1 . $s2;
        spew_raw("$tmp/fat.macho", $fat);
        my $nf = _clear_sections_in_macho("$tmp/fat.macho");
        my $fr = slurp("$tmp/fat.macho");
        my $both0 = substr($fr, 48 + $sect_off, $sect_size) eq ("\0" x $sect_size)
                 && substr($fr, 48 + length($s1) + $sect_off, $sect_size) eq ("\0" x $sect_size);
        $check->('清零:fat 双切片(Intel universal)各命中 1 节', $nf == 2 && $both0);
    }

    print "== 单元测试:rewrite_header_integrity(真实键序 size,offset,integrity)==\n";
    {
        my $old_h = 'A' x 64; my $new_h = 'B' x 64;
        my $old_b = '1' x 64; my $new_b = '2' x 64;
        my $dup_h = 'C' x 64;
        my $hdr = '{"files":{'
            . '"main.js":{"size":10,"offset":"0","integrity":{"algorithm":"SHA256","hash":"' . $old_h . '","blockSize":4194304,"blocks":["' . $old_b . '"]}},'
            . '"dup.js":{"size":10,"offset":"20","integrity":{"algorithm":"SHA256","hash":"' . $old_h . '","blocks":["' . $old_b . '"]}},'
            . '"other.js":{"size":5,"offset":"0","integrity":{"algorithm":"SHA256","hash":"' . $dup_h . '"}}}}';
        my $chg = { old_hash => $old_h, new_hash => $new_h, old_blocks => [$old_b], new_blocks => [$new_b] };
        my ($out, $n) = rewrite_header_integrity($hdr, { '0:10' => $chg }, []);
        $check->('rewrite: 恰好替换 1 条(offset 锚定)', $n == 1, "n=$n");
        $check->('rewrite: 等长', length($out) == length($hdr));
        $check->('rewrite: 目标条目已更新', $out =~ /"offset":"0","integrity":\{"algorithm":"SHA256","hash":"$new_h"[^}]*"blocks":\["$new_b"\]/);
        $check->('rewrite: 同 hash 不同 offset 的 dup 未被误伤', $out =~ /"offset":"20","integrity":\{"algorithm":"SHA256","hash":"$old_h","blocks":\["$old_b"\]/);
        $check->('rewrite: 其它条目不受影响', $out =~ /"other\.js".*?"hash":"$dup_h"/s);
        my $decoded = eval { JSON::PP::decode_json($out) };
        $check->('rewrite: JSON 仍合法', !$@ && ref $decoded);
    }

    # ---------- 场景 A:json 口径 + dup 共享内容 + unpacked 目标 ----------
    print "== 场景 A:json 口径 / dup 条目 / unpacked 目标 ==\n";
    my $srcA = "$tmp/A/Codex.app";
    my $destA = "$tmp/A/_dest/Codex 中文版.app";
    File::Path::make_path("$srcA/Contents", "$tmp/A/_dest");
    _mk_app_skeleton($srcA);
    my $zh_menu = '{"menu":{"file":"文件","edit":"编辑"}}';
    my $zh_ui = '{"ui":{"send":"发送","stop":"停止"}}';
    my ($asar_a, $json_a) = _build_asar([
        ['.vite/build/main.js',                       $main_js],
        ['.vite/build/early-bootstrap-439-abc123.js', $bootstrap_js],
        ['webview/assets/app-initial-x.js',           $initial_js],
        ['webview/assets/app-initial-unp.js',         $initial_js, 1],
        ['webview/assets/initialize-app-host-services-xyz.js', $init_hosts_js],
        ['webview/assets/general-settings-abc.js',    $gen_settings_js],
        ['native-menu-locales/zh-CN.json',            $zh_menu],
        ['webview/assets/zh-CN-ui.json',              $zh_ui],
        ['backup/dup-main.js',                        $main_js],   # 独立 offset、相同内容
        ['unused/data.bin',                           "\x00\x01\x02 padding \xff"],
    ], "$srcA/" . dirname($ASAR_REL) . "/app.asar.unpacked");
    spew_raw("$srcA/$ASAR_REL", $asar_a);
    my $hashA = Digest::SHA::sha256_hex($json_a);
    _write_plist($srcA, $hashA);

    my $r = do_inspect($srcA, 1);
    $check->('A inspect: 兼容', $r->{compatible}, $r->{reason});
    $check->('A inspect: 口径 json', ($r->{headerHashBasis} // '') eq 'json');
    $check->('A inspect: 目标 6 个(含新版形态)', scalar(@{$r->{patchFiles} || []}) == 6);

    my $old_size = -s "$srcA/$ASAR_REL";
    my $okA = eval { do_install($srcA, $destA); 1 };
    $check->('A install: 成功', $okA, $@);
    if ($okA) {
        my $new_size = -s "$destA/$ASAR_REL";
        my $na = Asar->new("$destA/$ASAR_REL");
        $check->('A asar 总长度不变', $new_size == $old_size, "$old_size -> $new_size");
        my $nm = $na->read_file_bytes('.vite/build/main.js');
        $check->('A R1 启用 (!0)', $nm =~ /\x60enable_i18n\x60,!0\)/ && $nm !~ /\x60enable_i18n\x60,!1\)/);
        $check->('A R2 整表达式替换', $nm =~ /return "zh-CN" +\}/ && $nm !~ /resolve\(/);
        $check->('A R3 整表达式替换', $nm =~ /return "zh-CN" +\}/ && $nm !~ /getEffective\(/);
        $check->('A trick 整段替换且未错位', $nm =~ /const tricky="zh-CN" +;/);
        $check->('A 干扰字符串未改写', $nm =~ /"a\.localeOverride"/);
        my $dup = $na->read_file_bytes('backup/dup-main.js');
        $check->('A dup 条目内容未被改', $dup eq $main_js);
        $check->('A dup 条目 integrity 未被误伤',
            lc($na->{files}{'backup/dup-main.js'}{integrity}{hash}) eq lc(Digest::SHA::sha256_hex($main_js)));
        my $mi = $na->{files}{'.vite/build/main.js'}{integrity};
        $check->('A main.js integrity 已同步', $mi && lc($mi->{hash}) eq lc(Digest::SHA::sha256_hex($nm)));
        my $up = "$destA/" . dirname($ASAR_REL) . "/app.asar.unpacked/webview/assets/app-initial-unp.js";
        $check->('A unpacked 目标已写回', -f $up && slurp($up) =~ /="zh-CN" +;/);
        my $ih = $na->read_file_bytes('webview/assets/initialize-app-host-services-xyz.js');
        $check->('A 新版 R1: initialize 开关已启用', $ih =~ /\x60enable_i18n\x60,!0\)/);
        $check->('A 新版 R2: we 整表达式替换', $ih =~ /r="zh-CN" +;/ && $ih !~ /we\(/);
        my $bs = $na->read_file_bytes('.vite/build/early-bootstrap-439-abc123.js');
        $check->('A 新版 R3: getEffective 整段替换且监听保留',
            $bs =~ /s2\("zh-CN" +\)/ && $bs =~ /onDidChange\(el\.Szl\.localeOverride\.key,/ && $bs !~ /getEffective\("zh-CN"/);
        my $ph = plist_asar_hash("$destA/$PLIST_REL");
        $check->('A plist 已更新为 json 口径新哈希',
            defined $ph && lc($ph) eq lc($na->header_hash()));
        $check->('A codesign 通过',
            system('/usr/bin/codesign --verify --strict ' . shell_quote($destA) . ' 1>/dev/null 2>&1') == 0);
        $check->('A 源 app 未被修改', Digest::SHA::sha256_hex(slurp("$srcA/$ASAR_REL")) eq Digest::SHA::sha256_hex($asar_a));
        $check->('A 重复安装被拒绝', !eval { do_install($srcA, $destA); 1 });
        my $r2 = do_inspect($destA, 1);
        $check->('A inspect(副本): alreadyEnabled=1', ($r2->{alreadyEnabled} // 0) == 1);
    }

    # ---------- 场景 B:full 口径 + 带空格 header ----------
    print "== 场景 B:full 口径 / 带空格 header ==\n";
    my $srcB = "$tmp/B/Codex.app";
    my $destB = "$tmp/B/_dest/Codex 中文版.app";
    File::Path::make_path("$srcB/Contents", "$tmp/B/_dest");
    _mk_app_skeleton($srcB);
    my ($asar_b, $json_b) = _build_asar([
        ['.vite/build/main.js',             $main_js],
        ['native-menu-locales/zh-CN.json',  $zh_menu],
        ['webview/assets/zh-CN-ui.json',    $zh_ui],
    ], "$srcB/" . dirname($ASAR_REL) . "/app.asar.unpacked", 1);
    spew_raw("$srcB/$ASAR_REL", $asar_b);
    my $ob = Asar->new("$srcB/$ASAR_REL");
    _write_plist($srcB, Digest::SHA::sha256_hex(_prefix_bytes("$srcB/$ASAR_REL", $ob->{data_start})));

    my $rb = do_inspect($srcB, 1);
    $check->('B inspect: 兼容', $rb->{compatible}, $rb->{reason});
    $check->('B inspect: 口径 full', ($rb->{headerHashBasis} // '') eq 'full');
    my $progB = "$tmp/progress-b.txt";
    my $okB = eval { do_install($srcB, $destB, $progB); 1 };
    $check->('B install: 成功', $okB, $@);
    $check->('B 进度文件:终态 done/100', -f $progB && slurp($progB) =~ /^STAGE done\nPCT 100\n/m);
    if ($okB) {
        my $nb = Asar->new("$destB/$ASAR_REL");
        my $want = Digest::SHA::sha256_hex(_prefix_bytes("$destB/$ASAR_REL", $nb->{data_start}));
        my $ph = plist_asar_hash("$destB/$PLIST_REL");
        $check->('B plist 按 full 口径写回', defined $ph && lc($ph) eq lc($want));
        my $mi = $nb->{files}{'.vite/build/main.js'}{integrity};
        my $nmb = $nb->read_file_bytes('.vite/build/main.js');
        $check->('B 带空格 header 下 integrity 精确同步',
            $mi && lc($mi->{hash}) eq lc(Digest::SHA::sha256_hex($nmb)));
    }

    # ---------- 场景 C:异常防御 ----------
    print "== 场景 C:异常防御 ==\n";
    my $srcC = "$tmp/C/Codex.app";
    File::Path::make_path("$srcC/Contents/Resources", "$srcC/Contents/MacOS");
    copy('/bin/ls', "$srcC/Contents/MacOS/Codex");
    _write_plist($srcC, undef);
    spew_raw("$srcC/$ASAR_REL", "not-an-asar-file-at-all........");
    my $rc1 = eval { do_inspect($srcC, 1); 1 };
    $check->('C 非法 asar 安全拒绝', !$rc1);
    _write_plist($srcC, ('a' x 64));
    my $rc2 = eval { do_inspect($srcC, 1); 1 };
    $check->('C 完整性记录不一致被拒', !$rc2);

    print "== uninstall ==\n";
    my $un = eval { do_uninstall($destA) };
    if ($un) {
        $check->('uninstall: 副本已移入废纸篓', !-d $destA);
    }
    else {
        print "  WARN  uninstall 环境限制未完成($@);改测拒绝逻辑\n";
        $check->('uninstall: 拒绝非本工具目录', !eval { do_uninstall("$tmp/A/_dest"); 1 });
    }

    print "== 单元测试:摘要槽等长替换 ==\n";
    {
        my $tf = "$tmp/slot-sample.bin";
        my $newfake = 'b' x 64;
        spew_raw($tf, "HEAD" . lc($hashA) . "MID" . uc($hashA) . "TAIL" . pack('H*', $hashA));
        my $n = replace_inplace_equal_length($tf, {
            lc($hashA) => $newfake, uc($hashA) => uc($newfake),
            pack('H*', $hashA) => pack('H*', $newfake),
        });
        my $after = slurp($tf);
        $check->('摘要槽替换:三形态全命中', $n == 3, "n=$n");
        $check->('摘要槽替换:旧值清除且等长',
            $after !~ /\Q$hashA\E/i && length($after) == 4 + 64 + 3 + 64 + 4 + 32);
    }

    print "\n== 结果:$npass 通过,$nfail 失败 ==\n";
    File::Path::remove_tree($tmp) unless $keep;
    return ($nfail == 0) ? 1 : 0;
}

# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------
sub usage {
    print <<"EOT";
用法:
  codex-zh inspect   [--app /Applications/Codex.app] [--json]
  codex-zh install   [--app /Applications/Codex.app] [--destination ~/Applications/Codex 中文版.app]
                     [--progress-file /tmp/xx.progress]   (键值行进度,供 GUI 轮询)
  codex-zh uninstall --app <中文版副本路径>
  codex-zh selftest  [--keep]
  codex-zh banner    (显示 SMO 横幅,供启动脚本调用)

无参数时显示本帮助。inspect 可输出 JSON。
安装创建独立中文版副本,目标已存在时不会覆盖。全过程无需联网。
EOT
}

sub expand_tilde {
    my ($p) = @_;
    return $p unless exists $ENV{HOME} && defined $p;
    if (substr($p, 0, 2) eq '~/') {
        $p = $ENV{HOME} . substr($p, 1);
    }
    elsif ($p eq '~') {
        $p = $ENV{HOME};
    }
    return $p;
}

sub main {
    my @argv = @ARGV;
    my $cmd = shift @argv // '';
    my ($app, $dest, $json, $keep, $progfile);
    while (@argv) {
        my $a = shift @argv;
        if    ($a eq '--app')           { $app  = expand_tilde(shift @argv); }
        elsif ($a eq '--destination')   { $dest = expand_tilde(shift @argv); }
        elsif ($a eq '--json')          { $json = 1; }
        elsif ($a eq '--keep')          { $keep = 1; }
        elsif ($a eq '--progress-file') { $progfile = expand_tilde(shift @argv); }
        else { fail "参数无效或重复:$a"; }
    }
    $app  //= '';
    if ($app eq '' && ($cmd eq 'inspect' || $cmd eq 'install')) {
        $app = find_codex_app();
        fail "未找到 Codex 桌面版(ChatGPT.app / Codex.app,Bundle ID $BUNDLE_ID)。可用 --app 指定路径。" unless defined $app;
        info "已定位应用:$app";
    }
    $app = '/Applications/Codex.app' if $app eq '';
    $dest //= ($ENV{HOME} // '/tmp') . '/Applications/Codex 中文版.app';

    # CODEX_ZH_NO_BANNER=1 供外层启动脚本(.command)自行显示横幅后跳过重复输出
    my $show_banner = $ENV{CODEX_ZH_NO_BANNER} ? 0 : 1;
    if    ($cmd eq 'inspect')   { my $r = do_inspect($app, $json ? 1 : 0); print JSON::PP->new->canonical(1)->pretty(1)->encode($r), "\n" if $json; }
    elsif ($cmd eq 'install')   {
        smo_banner(0) if $show_banner;
        my $ok = eval { do_install($app, $dest, $progfile); 1 };
        if (!$ok) {
            my $err = $@ || '未知错误';
            (my $first = $err) =~ s/\n.*//s;
            progress_write($progfile, 'error', 100, $first);
            die $err;
        }
    }
    elsif ($cmd eq 'uninstall') { smo_banner(0) if $show_banner; do_uninstall($app); }
    elsif ($cmd eq 'banner')    { smo_banner(1); exit 0; }
    elsif ($cmd eq 'selftest')  { exit(do_selftest($keep) ? 0 : 1); }
    elsif ($cmd eq '--help' || $cmd eq '-h' || $cmd eq '') { usage(); exit(($cmd eq '') ? 1 : 0); }
    else { fail "未知子命令:$cmd"; }
}

main();
