#!/usr/bin/env bash
# Public customer installer. The signing key is deliberately part of this
# reviewed bootstrap; a release can never supply or replace its own trust key.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
fail() { echo "东皇钟：$*" >&2; exit 1; }
trusted_command_paths() {
  local path mode
  for path in /usr /usr/bin /usr/local /usr/local/bin /usr/local/share /usr/local/share/donghuang-host; do
    if [ -L "$path" ]; then fail "管理命令目录是符号链接：$path"; fi
    [ -e "$path" ] || continue
    mode=$(stat -c '%a' -- "$path")
    [ -d "$path" ] && [ "$(stat -c '%u' -- "$path")" = 0 ] && (( (8#$mode & 022) == 0 )) || fail "管理命令目录必须由 root 所有且不可由其他用户写入：$path"
  done
  for path in /usr/bin/donghuang /usr/local/bin/donghuang; do
    [ ! -L "$path" ] || fail "其他程序的同名链接，未覆盖：$path"
    [ -e "$path" ] || continue
    [ -f "$path" ] && [ "$(stat -c '%u:%a:%h' -- "$path")" = 0:755:1 ] || fail "同名命令所有者、权限或链接数异常，未覆盖：$path"
  done
}
version_ok() { [[ $1 =~ ^v(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$ ]]; }
older() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }
fetch() { curl --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 12 --max-time 240 --retry 2 --max-filesize "$3" -o "$2" "$1"; }
python_runtime() {
  local py
  for py in python3.14 python3.13 python3.12 python3.11 python3.10 python3; do
    if type -P "$py" >/dev/null && "$py" -I -B -S -c 'import sys; sys.exit(sys.version_info < (3,10))' 2>/dev/null; then type -P "$py"; return 0; fi
  done
  return 1
}
read_platform() {
  local ID='' VERSION_ID='' PRETTY_NAME='' value
  if [[ -r /etc/os-release ]]; then . /etc/os-release; fi
  dh_id=$ID; dh_release=$VERSION_ID; dh_name=${PRETTY_NAME:-${ID:-未知发行版}}
  dh_os=$(uname -s); dh_cpu=$(uname -m); family=''; arch=''
  case "$dh_id" in ubuntu|debian) family=deb;; alinux|anolis|rocky|almalinux|rhel|centos|fedora) family=rpm;; esac
  case "$dh_cpu" in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; esac
  dh_systemd=''; dh_init='未检测到以 systemd 为 PID 1 的 Linux 系统'
  if [[ -d /run/systemd/system && -r /proc/1/comm && $(</proc/1/comm) = systemd ]]; then
    # Ask the running manager. The systemctl client may already be newer than PID 1.
    dh_init='无法读取运行中的 systemd 版本（请确认系统总线可访问）'
    if value=$(LC_ALL=C /usr/bin/systemctl --system --no-pager show --property=Version 2>/dev/null) && [[ $value =~ ^Version=v?([0-9]{1,4})([^0-9].*)?$ ]]; then
      dh_systemd=${BASH_REMATCH[1]}; dh_init="systemd $dh_systemd"
    fi
  fi
}
platform_reason() {
  local major=${dh_release%%.*}
  if [[ $dh_os != Linux || -z $family || -z $arch ]]; then
    echo "当前不支持 $dh_os / $dh_name / $dh_cpu；需要支持的 Linux systemd 主机和 x86_64 或 ARM64 架构。"; return
  fi
  case "$dh_id:$major" in centos:7|rhel:7|centos:6|rhel:6)
    echo "$dh_name / $dh_cpu（$dh_init）不在支持范围。主服务使用 StateDirectory=，需要 systemd 235 或更新版本；安装 dnf 或切换 Conda 不能解决。请在 Rocky Linux 9 或 Ubuntu 24.04 等受支持系统上安装。"; return;; esac
  if [[ $major =~ ^[0-9]{1,3}$ ]] && { { [[ $dh_id = ubuntu ]] && ((10#$major < 22)); } || { [[ $dh_id = debian ]] && ((10#$major < 12)); }; }; then
    echo "$dh_name 不在支持范围；需要 Ubuntu 22.04 或 Debian 12 及以上版本。"; return
  fi
  if [[ -z $dh_systemd ]]; then echo "$dh_name：$dh_init。"; return; fi
  if ((10#$dh_systemd < 235)); then
    echo "$dh_name / $dh_cpu 的 $dh_init 不支持本产品所需的 StateDirectory=（至少 systemd 235）。请使用受支持的系统；不建议单独更换系统的 systemd。"
  fi
}
package_manager() {
  local tool
  # Only use distribution commands; a Conda environment is not a system package manager.
  local PATH=/usr/sbin:/usr/bin:/sbin:/bin
  case "$family" in
    deb) type -P apt-get;;
    rpm) for tool in dnf yum; do if type -P "$tool"; then return 0; fi; done; return 1;;
    *) return 1;;
  esac
}
runtime_packages() {
  type -P nft >/dev/null || echo nftables
  type -P python3 >/dev/null || echo python3
  if ! python_runtime >/dev/null && { [[ $family = rpm ]] || type -P python3 >/dev/null; }; then echo python3.11; fi
  return 0
}
rpm_repair_note() {
  echo 'RPM 软件包自动修复另需通过 DNF4 执行器检查；yum 只用于安装依赖。'
}
diagnose_host() {
  local reason mgr py cmd; local -a missing=() manual=()
  read_platform; reason=$(platform_reason); mgr=$(package_manager) || mgr=''
  echo "系统：$dh_name（ID=${dh_id:-未知} VERSION_ID=${dh_release:-未知}） / $dh_cpu"
  echo "服务管理器：$dh_init；安装依赖用的包管理器：${mgr:-未找到}"
  if [[ -n $reason ]]; then echo "不兼容：$reason"; return 2; fi
  py=$(python_runtime) || py=''
  echo "系统路径中的 Python 3.10+：${py:-未找到}；nft：$(type -P nft || echo 未找到)"
  mapfile -t missing < <(runtime_packages)
  type -P openssl >/dev/null || missing+=(openssl)
  for cmd in systemctl journalctl flock useradd getent curl; do type -P "$cmd" >/dev/null || manual+=("$cmd"); done
  if ((${#missing[@]})); then echo "安装依赖缺项：${missing[*]}"; fi
  if ((${#manual[@]})); then echo "缺少基础系统命令：${manual[*]}"; fi
  if [[ $family = rpm ]]; then rpm_repair_note; fi
  if ((${#manual[@]})); then echo '请先通过发行版补齐基础命令后重试。'; return 3; fi
  if ((${#missing[@]})); then
    if [[ -n $mgr ]]; then echo "安装时将通过 $mgr 从已配置的软件源尝试补齐；诊断未访问软件源。"; else echo '没有可用包管理器；请通过发行版预装上列依赖后重试。'; fi
    return 3
  fi
  echo '平台和基础依赖检查通过。安装时仍会检查磁盘、目录权限、端口与发行包签名。'
}
manager_for_dependencies() {
  package_manager && return 0
  local names=apt-get; if [[ $family = rpm ]]; then names='dnf 或 yum'; fi
  fail "$dh_name 缺少依赖：$*；未找到可用的 $names。请通过发行版预装这些依赖后重试。"
}
packages() {
  [ "$#" -gt 0 ] || return 0
  local mgr; mgr=$(manager_for_dependencies "$@") || return 1
  echo "通过 $mgr 从本机已配置的软件源安装缺少的依赖：$*"
  case "${mgr##*/}" in
    apt-get) DEBIAN_FRONTEND=noninteractive "$mgr" -q update && DEBIAN_FRONTEND=noninteractive "$mgr" -q -y --no-install-recommends --no-remove install "$@";;
    dnf) "$mgr" -y --setopt=install_weak_deps=False install "$@";;
    yum) "$mgr" -y install "$@";;
  esac || fail "系统软件源未能用 ${mgr##*/} 安装：$*。请检查上方包管理器的错误；安装器不会更换软件源或替换系统 Python。"
}
install_main() {
  local repo=https://github.com/1994qrq/donghuang-releases requested=latest port=18083 chosen=false repair=false check=false sync=false
  local share=/usr/local/share/donghuang-host binary=/usr/local/bin/donghuang-host cli=/usr/local/bin/donghuang
  local family arch dh_os dh_id dh_name dh_release dh_cpu dh_systemd dh_init reason
  if [[ $# = 1 && $1 = --doctor ]]; then diagnose_host; return; fi
  while (($#)); do case "$1" in
    --version) [ "$#" -ge 2 ] && version_ok "$2" || fail '--version 需要 v主.次.修订'; requested=$2; shift 2;;
    --port) [ "$#" -ge 2 ] && [[ $2 =~ ^[1-9][0-9]{3,4}$ ]] && (( 10#$2 >= 1024 && 10#$2 <= 65535 )) || fail '--port 需要 1024–65535'; port=$2; chosen=true; shift 2;;
    --repair) repair=true; shift;; --check) check=true; shift;; --sync-channel) sync=true; shift;;
    --doctor) fail '--doctor 请单独使用：bash donghuang-install.sh --doctor';;
    --help|-h) echo '东皇钟 Linux 安装器 [--port 端口] [--version vX.Y.Z] [--check 仅检查发布] [--repair 同版恢复程序]；--doctor 单独使用：仅诊断本机，不联网、不安装、不需要 sudo'; return;;
    *) fail "未知选项：$1";; esac; done
  read_platform
  if ! $check; then reason=$(platform_reason); [[ -z $reason ]] || fail "$reason"; fi
  [[ $dh_os = Linux && -n $arch ]] || fail '仅提供 Linux x86_64 和 ARM64 安装包'
  [ "$(id -u)" = 0 ] || fail '请使用 sudo bash 运行安装器；已是 root 时可省略 sudo'
  trusted_command_paths
  local installed='' actual workroot=/var/tmp
  if [ -e "$binary" ] || [ -e "$share/VERSION" ]; then
    [ ! -L "$binary" ] && [ -f "$share/VERSION" ] || fail '已有安装不完整，请先核对版本文件及程序路径'
    installed=$(cat "$share/VERSION"); version_ok "$installed" || fail '原版本标记异常，未覆盖'
    $chosen && fail '已有安装请使用 sudo donghuang port 修改端口'
  fi
  if [ -L /usr/bin/donghuang ] || { [ -e /usr/bin/donghuang ] && { [ ! -f /usr/bin/donghuang ] || ! cmp -s /usr/bin/donghuang <(printf '#!/bin/sh\n# Donghuang system command\nexec /usr/local/bin/donghuang "$@"\n'); }; }; then fail '/usr/bin/donghuang 已由其他程序使用，未覆盖'; fi
  if command -v donghuang >/dev/null || [ -e "$cli" ] || [ -L "$cli" ]; then
    [ "$(command -v donghuang || true)" = "$cli" ] && [ ! -L "$cli" ] && grep -Fxq '# Donghuang local administrator menu' "$cli" || fail 'donghuang 命令已由其他程序使用，未覆盖'
  fi
  [ -d "$workroot" ] && [ ! -L "$workroot" ] || fail '缺少 /var/tmp 安装临时目录'
  local p need free
  for p in "$workroot" /usr/local /var/lib; do
    case "$p" in /var/tmp) need=196608;; /usr/local) need=98304;; *) need=65536;; esac
    free=$(df -Pk "$p" | awk 'END{print $4}'); [[ $free =~ ^[0-9]+$ ]] && ((free>=need)) || fail "$p 可用空间不足（至少需要 $((need/1024)) MiB）"
  done
  if [ -z "$installed" ] && ! $check; then
    local hex; hex=$(printf '%04X' "$port")
    local -a tables=(/proc/net/tcp); [ ! -r /proc/net/tcp6 ] || tables+=(/proc/net/tcp6)
    if awk -v p=":$hex" '$4=="0A" && $2~(p"$"){busy=1} END{exit !busy}' "${tables[@]}"; then fail "端口 $port 已在监听。可在安装命令末尾加 --port 18084 选择空闲端口"; fi
  fi
  command -v curl >/dev/null || fail '需要 curl；请先用系统包管理器安装 curl 和 ca-certificates'
  command -v flock >/dev/null || fail '缺少 util-linux 提供的 flock'
  umask 077
  exec 8>>/run/donghuang-bootstrap.lock; flock -n 8 || fail '已有安装程序正在运行'
  local work channel line1 line2 line3 v version name hash size manifest_hash
  work=$(mktemp -d "$workroot/donghuang-install.XXXXXXXX")
  # Only remove this mktemp directory. Preserve the path after the function returns.
  trap "rm -rf -- '$work'" EXIT
  if [ "$requested" = latest ]; then channel=$repo/releases/latest/download; else channel=$repo/releases/download/$requested; fi
  echo "检测到 $dh_name / $arch，正在核对官方发布签名…"
  fetch "$channel/CHANNEL" "$work/CHANNEL" 4096; fetch "$channel/CHANNEL.sig" "$work/CHANNEL.sig" 512
  cat > "$work/key.pem" <<'KEY'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEx71CEPmswZcpeT6X7WvMvme+RWWp
H44e3KarePPVTkmcBuDfDA4TlptXFuWg/IQ/6rFihRLwEYkY1a9QhxJuWg==
-----END PUBLIC KEY-----
KEY
  if ! command -v openssl >/dev/null; then if $check || $sync; then fail '签名检查需要系统 openssl；未安装依赖'; fi; packages openssl; fi
  openssl dgst -sha256 -verify "$work/key.pem" -signature "$work/CHANNEL.sig" "$work/CHANNEL" >/dev/null || fail '发布签名无效，未安装'
  [ "$(wc -l < "$work/CHANNEL")" -eq 3 ] || fail '发布清单格式错误'
  mapfile -t lines < "$work/CHANNEL"; version=${lines[0]}; version_ok "$version" && ! older "$version" v0.1.62 || fail '版本低于公开发行下限'
  [ "$requested" = latest ] || [ "$requested" = "$version" ] || fail '固定版本与签名不符'
  [ -z "$installed" ] || ! older "$version" "$installed" || fail '不允许自动降级，请使用本机备份恢复流程'
  for v in 1 2; do
    read -r name hash size manifest_hash extra <<< "${lines[v]}"
    [[ $name = "$([ "$v" = 1 ] && echo amd64 || echo arm64)" && $hash =~ ^[0-9a-f]{64}$ && $manifest_hash =~ ^[0-9a-f]{64}$ && $size =~ ^[1-9][0-9]{0,8}$ && -z ${extra:-} ]] && ((size <= 134217728)) || fail '签名清单字段无效'
    if [ "$name" = "$arch" ]; then actual=$hash; archive_size=$size; sums=$manifest_hash; fi
  done
  echo "官方稳定包：$version；当前：${installed:-未安装}；下载大小：$(( (archive_size+1048575)/1048576 )) MiB。"
  $check && return 0
  if $sync; then
    [ -n "$installed" ] || fail '需要先安装主服务'
    if [ "$installed" = "$version" ]; then echo "CHANNEL $version $actual $arch"; return 0; fi
  fi
  if [ "$installed" = "$version" ] && ! $repair; then
    [ -x "$cli" ] && [ -f "$share/installed-files.sha256" ] && [ -f "$share/SHA256SUMS" ] && printf '%s  %s\n' "$sums" "$share/SHA256SUMS" | sha256sum -c --status && (cd / && sha256sum -c --status "$share/installed-files.sha256") && "$cli" status || fail '同版安装不完整或服务异常。可用 --repair 通过备份流程重装程序；不会重置业务配置或密钥。'
    echo '已是此版本，本次没有重启或重装。'; return 0
  fi
  local archive="donghuang-host-linux-$arch.tar.gz" py; local -a missing=()
  # Give a useful answer before downloading a host archive that cannot be used.
  # Do not mutate the package database until the downloaded archive is verified.
  if ! $sync; then
    mapfile -t missing < <(runtime_packages)
    if ((${#missing[@]})); then manager_for_dependencies "${missing[@]}" >/dev/null; fi
  fi
  fetch "$repo/releases/download/$version/$archive" "$work/$archive" "$archive_size"
  [ "$(wc -c < "$work/$archive")" -eq "$archive_size" ] && printf '%s  %s\n' "$actual" "$work/$archive" | sha256sum -c --status || fail '下载不完整或 SHA256 不符，未安装'
  if $sync; then
    py=$(python_runtime) || fail '已安装的 Python 解释器不可用'
    "$py" -I - "$share/release-store.py" "$work/$archive" "$actual" <<'PY'
import sys,runpy,pathlib
s=runpy.run_path(sys.argv[1]);s['stage'](pathlib.Path(sys.argv[2]),sys.argv[3],public=True)
PY
    echo "CHANNEL $version $actual $arch"; return 0
  fi
  packages "${missing[@]}"; py=$(python_runtime) || fail '系统软件源未提供 Python 3.10+；请并行安装受支持的 Python 后重试，无需替换系统 Python'
  "$py" -I - "$work" "$archive" "$arch" "$version" <<'PY'
import os, pathlib, re, sys, tarfile, shutil
root=pathlib.Path(sys.argv[1]); prefix='donghuang-host-linux-'+sys.argv[3]; dest=root/prefix; dest.mkdir(mode=0o700); total=0; seen=set()
with tarfile.open(root/sys.argv[2], 'r|gz') as tar:
    for m in tar:
        name=m.name.removeprefix(prefix+'/'); total+=m.size
        if m.name!=prefix+'/'+name or not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9._-]{0,80}',name) or name in seen or not m.isreg() or len(seen)>=96 or m.size<0 or total>256<<20: sys.exit('发行包包含非法成员')
        seen.add(name)
        with tar.extractfile(m) as src,(dest/name).open('xb') as out:shutil.copyfileobj(src,out)
        (dest/name).chmod(0o700 if name in ('install.sh','donghuang-host') else 0o600)
if (dest/'VERSION').read_text().strip()!=sys.argv[4] or (dest/'ARCH').read_text().strip()!=sys.argv[3]: sys.exit('发行包版本或架构不符')
rows=(dest/'SHA256SUMS').read_text().splitlines(); names=[]
for row in rows:
    m=re.fullmatch(r'[0-9a-f]{64} [ *]([a-zA-Z0-9][a-zA-Z0-9._-]{0,80})',row)
    if not m:sys.exit('无效逐文件清单')
    names.append(m[1])
if len(names)!=len(set(names)) or set(names)!=seen-{'SHA256SUMS'}:sys.exit('发行包文件清单不一致')
PY
  local pkg="$work/donghuang-host-linux-$arch"
  printf '%s  %s\n' "$sums" "$pkg/SHA256SUMS" | sha256sum -c --status && (cd "$pkg" && sha256sum -c --status SHA256SUMS) || fail '包内文件验签失败'
  if [ -n "$installed" ]; then
    "$py" -I - "$pkg" <<'PY'
import runpy,sys,pathlib
c=runpy.run_path(str(pathlib.Path(sys.argv[1])/'update-control.py')); c['repair_idle'](); c['disk_check']()
if c['observers']():sys.exit('有连续观察任务，未升级')
PY
    "$py" -I "$pkg/update.py" --archive "$work/$archive" --sha256 "$actual"
    "$cli" status
  else
    bash "$pkg/install.sh" --port "$port"
    install -m 0644 /dev/null "$share/public-channel"
  fi
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then install_main "$@"; fi
