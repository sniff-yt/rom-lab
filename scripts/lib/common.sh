# shellcheck shell=bash
# Shared helpers for scripts/unpack, scripts/apply-mods, scripts/repack.
# Sourced, not executed.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export LIB_DIR
DEFAULT_CTX="u:object_r:system_file:s0"

log()  { printf '[%s] %s\n' "$(basename "$0")" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(basename "$0")" "$*" >&2; exit 1; }

need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing tool: $c (see README: Tools)"
  done
}

lp()      { python3 "$LIB_DIR/lp.py" "$@"; }
gpt()     { python3 "$LIB_DIR/gpt.py" "$@"; }
avbtool() { python3 "$LIB_DIR/avbtool.py" "$@"; }
avbh()    { python3 "$LIB_DIR/avbhelper.py" "$@"; }

# Magic-number sniffing. Prints one of: zip sparse gpt super ext4 erofs unknown
detect_kind() {
  local f="$1" m
  m="$(od -An -tx1 -N4 "$f" | tr -d ' \n')"
  case "$m" in
    504b0304) echo zip; return ;;
    3aff26ed) echo sparse; return ;;
  esac
  if [ "$(od -An -tx1 -j512 -N8 "$f" | tr -d ' \n')" = "4546492050415254" ]; then
    echo gpt; return
  fi
  if [ "$(od -An -tx1 -j4096 -N4 "$f" | tr -d ' \n')" = "67446c61" ]; then
    echo super; return
  fi
  if [ "$(od -An -tx1 -j1080 -N2 "$f" | tr -d ' \n')" = "53ef" ]; then
    echo ext4; return
  fi
  if [ "$(od -An -tx1 -j1024 -N4 "$f" | tr -d ' \n')" = "e2e1f5e0" ]; then
    echo erofs; return
  fi
  echo unknown
}

load_state() {
  WORK="$(cd "$1" && pwd)"
  [ -f "$WORK/state.env" ] || die "$WORK/state.env missing; run scripts/unpack first"
  # shellcheck disable=SC1091
  . "$WORK/state.env"
}

# ---------------------------------------------------------------------------
# Filesystem backend. FS=ext4 edits $FS_IMG in place with debugfs (keeps every
# untouched file, owner, mode, SELinux label and capability byte-for-byte).
# FS=erofs works on the extracted tree in $ROOT_DIR.
# All paths are absolute paths inside the image (e.g. /system/build.prop).
# ---------------------------------------------------------------------------

check_path() {
  case "$1" in
    *' '*|*'"'*|*"'"*) die "unsupported character in path: $1" ;;
    /*) ;;
    *) die "path must be absolute: $1" ;;
  esac
}

dbg()  { debugfs -R "$1" "$FS_IMG" 2>/dev/null; }
dbgw() { debugfs -w -f "$1" "$FS_IMG" >/dev/null 2>"$WORK/.debugfs.err" || die "debugfs failed: $(cat "$WORK/.debugfs.err")"; }

fs_exists() {
  check_path "$1"
  if [ "$FS" = ext4 ]; then
    dbg "stat $1" | grep -q '^Inode:'
  else
    [ -e "$ROOT_DIR$1" ] || [ -L "$ROOT_DIR$1" ]
  fi
}

fs_is_dir() {
  if [ "$FS" = ext4 ]; then
    dbg "stat $1" | grep -q 'Type: directory'
  else
    [ -d "$ROOT_DIR$1" ] && [ ! -L "$ROOT_DIR$1" ]
  fi
}

fs_get_ctx() {  # prints the SELinux label of a path, empty if none
  if [ "$FS" = ext4 ]; then
    dbg "ea_get $1 security.selinux" | sed -n 's/.*= "\([^"\\]*\).*/\1/p' | head -n1
  else
    getfattr --absolute-names --only-values -n security.selinux "$ROOT_DIR$1" 2>/dev/null | tr -d '\0' || true
  fi
}

fs_read() {  # fs_read <img path> <local file>
  check_path "$1"
  if [ "$FS" = ext4 ]; then
    debugfs -R "dump $1 $2" "$FS_IMG" >/dev/null 2>&1
    [ -f "$2" ] || die "could not read $1"
  else
    cp "$ROOT_DIR$1" "$2"
  fi
}

fs_rm_rf() {
  check_path "$1"
  fs_exists "$1" || return 0
  if [ "$FS" = ext4 ]; then
    local cmds="$WORK/.rm.cmds"
    : > "$cmds"
    _ext4_rm_tree "$1" "$cmds"
    dbgw "$cmds"
  else
    rm -rf "${ROOT_DIR:?}$1"
  fi
  if fs_exists "$1"; then die "failed to remove $1"; fi
}

_ext4_rm_tree() {  # appends rm/rmdir commands, children first
  local p="$1" out="$2" line mode name
  if fs_is_dir "$p"; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      mode="$(printf '%s' "$line" | cut -d/ -f3)"
      name="$(printf '%s' "$line" | cut -d/ -f6)"
      [ "$name" = . ] || [ "$name" = .. ] || [ -z "$name" ] && continue
      case "$mode" in
        04*) _ext4_rm_tree "$p/$name" "$out" ;;
        *) echo "rm $p/$name" >> "$out" ;;
      esac
    done < <(dbg "ls -p $p")
    echo "rmdir $p" >> "$out"
  else
    echo "rm $p" >> "$out"
  fi
}

fs_mkdir_p() {  # fs_mkdir_p <dir> [ctx]   (new dirs: 0755 root:root)
  check_path "$1"
  local ctx="${2:-}" cur="" part rest="${1#/}"
  local IFS=/
  for part in $rest; do
    cur="$cur/$part"
    if ! fs_exists "$cur"; then
      local c="$ctx"
      [ -n "$c" ] || c="$(fs_get_ctx "$(dirname "$cur")")"
      [ -n "$c" ] || c="$DEFAULT_CTX"
      if [ "$FS" = ext4 ]; then
        printf '%s\0' "$c" > "$WORK/.ctx"
        printf 'mkdir %s\nsif %s mode 040755\nsif %s uid 0\nsif %s gid 0\nea_set -f %s %s security.selinux\n' \
          "$cur" "$cur" "$cur" "$cur" "$WORK/.ctx" "$cur" > "$WORK/.mkdir.cmds"
        dbgw "$WORK/.mkdir.cmds"
      else
        mkdir "$ROOT_DIR$cur"
        chmod 0755 "$ROOT_DIR$cur"
        chown 0:0 "$ROOT_DIR$cur"
        setfattr -n security.selinux -v "$c" "$ROOT_DIR$cur"
      fi
    fi
  done
}

# fs_write <local file> <img path> [mode] [uid] [gid] [ctx]
# Replacing an existing file keeps its mode/owner/label unless given.
fs_write() {
  local src="$1" dst="$2" mode="${3:-}" uid="${4:-}" gid="${5:-}" ctx="${6:-}"
  check_path "$dst"
  [ -f "$src" ] || die "no such local file: $src"
  if fs_exists "$dst"; then
    if fs_is_dir "$dst"; then die "$dst is a directory"; fi
    if [ "$FS" = ext4 ]; then
      local st
      st="$(dbg "stat $dst")"
      [ -n "$mode" ] || mode="0$(printf '%s\n' "$st" | sed -n 's/.*Mode: *\([0-7]*\).*/\1/p' | head -n1)"
      [ -n "$uid" ]  || uid="$(printf '%s\n' "$st" | sed -n 's/^User: *\([0-9]*\).*/\1/p' | head -n1)"
      [ -n "$gid" ]  || gid="$(printf '%s\n' "$st" | sed -n 's/.*Group: *\([0-9]*\).*/\1/p' | head -n1)"
    else
      [ -n "$mode" ] || mode="$(stat -c '%a' "$ROOT_DIR$dst")"
      [ -n "$uid" ]  || uid="$(stat -c '%u' "$ROOT_DIR$dst")"
      [ -n "$gid" ]  || gid="$(stat -c '%g' "$ROOT_DIR$dst")"
    fi
    [ -n "$ctx" ] || ctx="$(fs_get_ctx "$dst")"
    fs_rm_rf "$dst"
  fi
  fs_mkdir_p "$(dirname "$dst")"
  [ -n "$mode" ] || mode=0644
  [ -n "$uid" ] || uid=0
  [ -n "$gid" ] || gid=0
  [ -n "$ctx" ] || ctx="$(fs_get_ctx "$(dirname "$dst")")"
  [ -n "$ctx" ] || ctx="$DEFAULT_CTX"
  if [ "$FS" = ext4 ]; then
    printf '%s\0' "$ctx" > "$WORK/.ctx"
    printf 'write %s %s\nsif %s mode 0100%s\nsif %s uid %s\nsif %s gid %s\nea_set -f %s %s security.selinux\n' \
      "$src" "$dst" "$dst" "$(printf '%04o' "$((8#$mode & 07777))")" "$dst" "$uid" "$dst" "$gid" "$WORK/.ctx" "$dst" \
      > "$WORK/.write.cmds"
    dbgw "$WORK/.write.cmds"
  else
    cp "$src" "$ROOT_DIR$dst"
    chown "$uid:$gid" "$ROOT_DIR$dst"
    chmod "$mode" "$ROOT_DIR$dst"
    setfattr -n security.selinux -v "$ctx" "$ROOT_DIR$dst"
  fi
  fs_exists "$dst" || die "write of $dst did not stick"
}

fs_set_meta() {  # fs_set_meta <path> <mode> <uid> <gid> <ctx>
  local p="$1" mode="$2" uid="$3" gid="$4" ctx="$5" type=0100
  check_path "$p"
  fs_exists "$p" || die "perms: $p does not exist"
  if fs_is_dir "$p"; then type=040; fi
  if [ "$FS" = ext4 ]; then
    printf '%s\0' "$ctx" > "$WORK/.ctx"
    printf 'sif %s mode %s%s\nsif %s uid %s\nsif %s gid %s\nea_set -f %s %s security.selinux\n' \
      "$p" "$type" "$(printf '%04o' "$((8#$mode & 07777))")" "$p" "$uid" "$p" "$gid" "$WORK/.ctx" "$p" > "$WORK/.meta.cmds"
    dbgw "$WORK/.meta.cmds"
  else
    chown "$uid:$gid" "$ROOT_DIR$p"
    chmod "$mode" "$ROOT_DIR$p"
    setfattr -n security.selinux -v "$ctx" "$ROOT_DIR$p"
  fi
}
