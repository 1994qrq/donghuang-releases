#!/usr/bin/env bash
# Public customer installer. The signing key is deliberately part of this
# reviewed bootstrap; a release can never supply or replace its own trust key.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
fail() { echo "东皇钟：$*" >&2; exit 1; }
version_ok() { [[ $1 =~ ^v(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$ ]]; }
older() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$1" ]; }
fetch() { curl --disable --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 12 --max-time 240 --retry 2 --max-filesize "$3" -o "$2" "$1"; }
python_runtime() {
  local py
  for py in python3.14 python3.13 python3.12 python3.11 python3.10 python3; do
    if command -v "$py" >/dev/null && "$py" -I -c 'import sys; sys.exit(sys.version_info < (3,10))'; then command -v "$py"; return 0; fi
  done
  return 1
}
packages() {
  [ "$#" -gt 0 ] || return 0
  echo "从本机已配置的软件源安装缺少的依赖：$*"
  if [ "$family" = deb ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get -q update && apt-get -q -y --no-install-recommends --no-remove install "$@"
  else
    dnf -y --setopt=install_weak_deps=False install "$@"
  fi
}
install_main() {
  local repo=https://github.com/1994qrq/donghuang-releases requested=latest port=18083 chosen=false repair=false check=false sync=false
  local share=/usr/local/share/donghuang-host binary=/usr/local/bin/donghuang-host cli=/usr/local/bin/donghuang
  while (($#)); do case "$1" in
    --version) [ "$#" -ge 2 ] && version_ok "$2" || fail '--version 需要 v主.次.修订'; requested=$2; shift 2;;
    --port) [ "$#" -ge 2 ] && [[ $2 =~ ^[1-9][0-9]{3,4}$ ]] && (( 10#$2 >= 1024 && 10#$2 <= 65535 )) || fail '--port 需要 1024–65535'; port=$2; chosen=true; shift 2;;
    --repair) repair=true; shift;; --check) check=true; shift;; --sync-channel) sync=true; shift;;
    --help|-h) echo '东皇钟 Linux 安装器 [--port 端口] [--version vX.Y.Z] [--check 仅检查发布] [--repair 同版恢复程序]'; return;;
    *) fail "未知选项：$1";; esac; done
  [ "$(uname -s)" = Linux ] && [ -r /etc/os-release ] && [ -d /run/systemd/system ] || fail '需要运行 systemd 的 Linux 服务器，不支持普通 Docker 容器、macOS 或 Windows'
  [ "$(id -u)" = 0 ] || fail '请使用 sudo bash 运行安装器；已是 root 时可省略 sudo'
  . /etc/os-release
  local family arch
  case "$ID" in ubuntu|debian) family=deb;; alinux|anolis|rocky|almalinux|rhel|centos|fedora) family=rpm;; *) fail "尚不支持 ${PRETTY_NAME:-$ID}";; esac
  if { [ "$ID" = ubuntu ] && [[ ${VERSION_ID%%.*} =~ ^[0-9]+$ ]] && (( ${VERSION_ID%%.*} < 22 )); } || { [ "$ID" = debian ] && [[ ${VERSION_ID%%.*} =~ ^[0-9]+$ ]] && (( ${VERSION_ID%%.*} < 12 )); }; then fail '需要 Ubuntu 22.04 或 Debian 12 及以上版本'; fi
  if [ "$family" = rpm ]; then command -v dnf >/dev/null || fail '需要使用 dnf 的受支持 RPM 发行版'; fi
  case "$(uname -m)" in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; *) fail '当前只提供 x86_64 和 ARM64 安装包';; esac
  local installed='' actual workroot=/var/tmp
  if [ -e "$binary" ] || [ -e "$share/VERSION" ]; then
    [ ! -L "$binary" ] && [ -f "$share/VERSION" ] || fail '已有安装不完整，请先核对版本文件及程序路径'
    installed=$(cat "$share/VERSION"); version_ok "$installed" || fail '原版本标记异常，未覆盖'
    $chosen && fail '已有安装请使用 sudo donghuang port 修改端口'
  fi
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
  echo "检测到 ${PRETTY_NAME:-$ID} / $arch，正在核对官方发布签名…"
  fetch "$channel/CHANNEL" "$work/CHANNEL" 4096; fetch "$channel/CHANNEL.sig" "$work/CHANNEL.sig" 512
  cat > "$work/key.pem" <<'KEY'
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEx71CEPmswZcpeT6X7WvMvme+RWWp
H44e3KarePPVTkmcBuDfDA4TlptXFuWg/IQ/6rFihRLwEYkY1a9QhxJuWg==
-----END PUBLIC KEY-----
KEY
  if ! command -v openssl >/dev/null; then $check && fail '只读检查需要 openssl'; packages openssl; fi
  openssl dgst -sha256 -verify "$work/key.pem" -signature "$work/CHANNEL.sig" "$work/CHANNEL" >/dev/null || fail '发布签名无效，未安装'
  [ "$(wc -l < "$work/CHANNEL")" -eq 3 ] || fail '发布清单格式错误'
  mapfile -t lines < "$work/CHANNEL"; version=${lines[0]}; version_ok "$version" && ! older "$version" v0.1.58 || fail '版本低于公开发行下限'
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
  local archive="donghuang-host-linux-$arch.tar.gz" py mgr; local -a missing=()
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
  command -v nft >/dev/null || missing+=(nftables)
  command -v python3 >/dev/null || missing+=(python3)
  if ! python_runtime >/dev/null; then
    if [ "$family" = rpm ]; then missing+=(python3.11); elif command -v python3 >/dev/null; then missing+=(python3.11); fi
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
install_main "$@"
