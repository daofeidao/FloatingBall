#!/bin/bash
# 产出 build/FloatingBall.tipa
#   ./ipabuild.sh            正式包
#   ./ipabuild.sh --debug    调试包（不 strip，留符号）
#
# ⚠️ 本文件必须是 LF 行尾。CRLF 会让 `set -e` 那一行报 invalid option name，
#    报错位置极其误导（详见 E:\文档\默认项目\MEMORY.md）。
if [[ $* == *--scriptdebug* ]]; then
    set -x
fi
set -e

WORKING_LOCATION="$(pwd)"
APP_BUILD_FILES="$WORKING_LOCATION/layout/Applications/FloatingBall.app"
DEBUG_LOCATION="$WORKING_LOCATION/.theos/obj/debug"
RELEASE_LOCATION="$WORKING_LOCATION/.theos/obj"
if [[ $* == *--debug* ]]; then
    BUILD_LOCATION="$DEBUG_LOCATION/FloatingBall.app"
else
    BUILD_LOCATION="$RELEASE_LOCATION/FloatingBall.app"
fi

if [[ $* == *--clean* ]]; then
    echo "[*] Cleaning..."
    rm -rf build
    make clean
fi

if [ ! -d "build" ]; then
    mkdir build
fi
if [ -e "build/FloatingBall.tipa" ]; then
    rm -f "build/FloatingBall.tipa"
fi

if ! type "gmake" >/dev/null; then
    echo "[!] gmake not found, using macOS bundled make instead"
    make clean
    if [[ $* == *--debug* ]]; then
        make
    else
        make FINALPACKAGE=1
    fi
else
    gmake clean
    if [[ $* == *--debug* ]]; then
        gmake -j"$(sysctl -n machdep.cpu.thread_count)"
    else
        gmake -j"$(sysctl -n machdep.cpu.thread_count)" FINALPACKAGE=1
    fi
fi

if [ -d "$BUILD_LOCATION" ]; then
    echo "Adding application files"
    cp -r "$APP_BUILD_FILES/Info.plist" "$BUILD_LOCATION/Info.plist"
    # 图标 + 球贴图：把 layout 里的 png 全拷过去。
    # ⚠️ 这里必须用 if，不能用 `[ -f x ] && cp`：
    #    后者在文件不存在时给 `for` 留一个退出码 1，配上 `set -e` 会直接把脚本干掉。
    # ⚠️ 不能只列 AppIcon 那几个名字 —— 球贴图（BallDot 等）也要进包，
    #    少一张不会编译报错，只会「手机上换样式没反应」，极难查。
    for f in "$APP_BUILD_FILES"/*.png; do
        if [ -f "$f" ]; then
            cp "$f" "$BUILD_LOCATION/"
        fi
    done
    for d in en.lproj zh-Hans.lproj; do
        if [ -d "$APP_BUILD_FILES/$d" ]; then
            cp -r "$APP_BUILD_FILES/$d" "$BUILD_LOCATION/"
        fi
    done

    echo "Creating payload"
    cd build
    rm -rf Payload
    mkdir Payload
    cp -r "$BUILD_LOCATION" Payload/FloatingBall.app

    echo "Archiving"
    if [[ $* != *--debug* ]]; then
        strip Payload/FloatingBall.app/FloatingBall
    fi

    # 硬闸：确认 entitlements 真的进去了。少了这个，装到手机上就是普通身份。
    if ! /usr/bin/codesign -d --entitlements :- Payload/FloatingBall.app 2>/dev/null \
         | grep -q "assistivetouch.daemon"; then
        # ldid 签的名，codesign 查不到时退回用 ldid -e
        if ! ldid -e Payload/FloatingBall.app/FloatingBall | grep -q "assistivetouch.daemon"; then
            echo "[!] 致命：entitlements 里没有 assistivetouch.daemon，装上去悬浮球起不来"
            exit 1
        fi
    fi
    echo "[*] entitlements 自检通过"

    # 硬闸：三张球贴图必须都在。少了**不会**编译报错，
    # 只会在手机上表现为「换样式没反应」，所以必须在这里拦住。
    for n in BallDot BallPlain BallWhite; do
        if [ ! -f "Payload/FloatingBall.app/$n.png" ]; then
            echo "[!] 致命：Payload 里缺 $n.png（App 里换样式会没反应）"
            exit 1
        fi
    done
    echo "[*] 球贴图自检通过（BallDot / BallPlain / BallWhite）"

    zip -qr FloatingBall.tipa Payload
    rm -rf Payload
    echo "[*] 产出: build/FloatingBall.tipa"
fi
