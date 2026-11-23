#!/bin/bash
# 多分区 U-Boot(FIP) + BL2 构建执行器（供 .github/workflows/*-multi-layout*.yml 调用）
#
# 用法：
#   bash .github/scripts/build-multi-layout.sh "<board1> <board2> ..."
#
# 依赖 workflow 里已有的环境变量：SOC / MULTI_LAYOUT / FIXED_MTDPARTS / COPY_BL2，
# 以及可选的 VARIANT（默认 default）、VERSION（默认 2025）。
#
# 设计要点（都是踩过的坑）：
#   1. build.sh 的退出码用 PIPESTATUS 取，不能被 tee 掩盖；
#   2. 产物名是 fip-<soc>_<board>_... / bl2-<soc>_<board>_...，fip/bl2 前缀在机型名**之前**，
#      判断必须用「文件名里同时含机型名和 fip/bl2」，不能写成 *<board>*fip*；
#   3. 产物优先从 output/ 取，取不到就在仓库里兜底搜（maxdepth 4）；
#   4. 失败原因通过 ::error 注解输出日志尾部 —— Actions 日志要登录才能看，注解匿名可读。

set -eo pipefail

BOARDS="${1:?用法: build-multi-layout.sh \"<board1> <board2> ...\"}"
VARIANT="${VARIANT:-default}"
VERSION="${VERSION:-2025}"
SOC="${SOC:?缺少 SOC}"
MULTI_LAYOUT="${MULTI_LAYOUT:-1}"
FIXED_MTDPARTS="${FIXED_MTDPARTS:-1}"
COPY_BL2="${COPY_BL2:-1}"

mkdir -p out
FAIL=0

# 把日志尾部转成一条公开可读的注解（% 转义 + 换行转 %0A）
annotate_tail() {
    local file="$1" title="$2" msg=""
    [ -f "$file" ] || return 0
    msg=$(tail -n 25 "$file" 2>/dev/null | awk '{gsub(/%/, "%25"); printf "%s%%0A", $0}')
    if [ -n "$msg" ]; then
        echo "::error title=${title}::${msg}"
    fi
    return 0
}

for b in $BOARDS; do
    echo ""
    echo "================= BUILD $b ================="
    echo "SOC=$SOC VARIANT=$VARIANT VERSION=$VERSION MULTI_LAYOUT=$MULTI_LAYOUT FIXED_MTDPARTS=$FIXED_MTDPARTS COPY_BL2=$COPY_BL2"

    set +e
    BOARD="$b" SOC="$SOC" VERSION="$VERSION" VARIANT="$VARIANT" \
        MULTI_LAYOUT="$MULTI_LAYOUT" FIXED_MTDPARTS="$FIXED_MTDPARTS" COPY_BL2="$COPY_BL2" \
        ./build.sh </dev/null 2>&1 | tee "build-$b.log"
    rc=${PIPESTATUS[0]}
    set -e

    if [ "$rc" = "0" ]; then
        echo "OK   $b build.sh 返回 0"
    else
        echo "::error title=$b build.sh 失败::$b build.sh 退出码 $rc"
        annotate_tail "build-$b.log" "$b 日志尾部"
        FAIL=1
    fi

    # ---- 产物收集：output/ 优先，找不到就全仓兜底 ----
    for f in output/*"$b"*; do
        [ -f "$f" ] || continue
        cp -f "$f" out/
    done
    if ! ls out/*"$b"* >/dev/null 2>&1; then
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            cp -f "$f" out/
        done < <(find . -maxdepth 4 -type f -name "*$b*" 2>/dev/null | grep -E '/(fip|bl2)[^/]*$' || true)
    fi

    # ---- 断言：fip 必须有，bl2 视 ATF secure boot 开关而定 ----
    if ls out/*"$b"* 2>/dev/null | grep -q 'fip'; then
        echo "OK   $b fip 就绪"
    else
        echo "::error title=$b 缺 fip::$b 没有产出 fip.bin"
        echo "----- output/ -----"
        ls -l output 2>/dev/null || echo "(没有 output 目录)"
        echo "----- 仓库内 fip*.bin -----"
        find . -maxdepth 4 -type f -name 'fip*.bin' 2>/dev/null | head -10 || true
        annotate_tail "build-$b.log" "$b 日志尾部"
        FAIL=1
    fi

    if ls out/*"$b"* 2>/dev/null | grep -q 'bl2'; then
        echo "OK   $b bl2 就绪"
    else
        echo "::warning title=$b 缺 bl2::$b 没有产出 bl2.img（ATF 配置里可能开了 secure boot）"
    fi

    if ls out/*"$b"* 2>/dev/null | grep -q 'multi-layout'; then
        echo "OK   $b 产物带 multi-layout 标识"
    else
        echo "::warning::$b 产物名里没有 multi-layout 标识，确认 MULTI_LAYOUT 是否真的生效"
    fi
done

echo ""
echo "================= out/ ================="
ls -lh out || true
if [ -n "$(ls out 2>/dev/null)" ]; then
    ( cd out && sha256sum ./* > sha256sums.txt )
fi

if [ "$FAIL" != "0" ]; then
    echo "::error::有机型构建或校验失败，上面注解里带了日志尾部"
    echo "===== output/ ====="
    ls -lh output 2>/dev/null || echo "(没有 output 目录，说明 build.sh 没跑到 copy_outputs)"
    exit 1
fi

echo "全部机型构建完成"