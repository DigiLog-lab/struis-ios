#!/bin/bash
# emp-toolkit(emp-tool / emp-ot / emp-zk)を取得してビルドし、aes_open を作る。
#   build.sh <作業ディレクトリ>
set -euo pipefail
ROOT="${1:?work dir}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$ROOT"
cd "$ROOT"
PREFIX="$ROOT/inst"
OPENSSL_DIR="$(brew --prefix openssl@3 2>/dev/null || true)"
for r in emp-tool emp-ot emp-zk; do
  [ -d "$r" ] || git clone -q "https://github.com/emp-toolkit/$r"
  echo "$r $(git -C "$r" rev-parse HEAD)"
  ( cd "$r" && cmake -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
      ${OPENSSL_DIR:+-DOPENSSL_ROOT_DIR="$OPENSSL_DIR"} . >cmake.log 2>&1 \
    && make -j3 >make.log 2>&1 && make install >install.log 2>&1 ) \
    || { echo "BUILD FAILED: $r"; tail -40 "$r/cmake.log" "$r/make.log" 2>/dev/null; exit 1; }
done
ls "$PREFIX/lib" "$PREFIX/cmake" 2>/dev/null | head -40
echo "emp built"
