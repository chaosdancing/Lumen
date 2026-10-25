#!/bin/bash
# 把 Lumen 装到已连接的 iPhone / iPad 上。
# 前提：
#   1) 设备已开启「开发者模式」（设置 → 隐私与安全性 → 开发者模式）
#   2) 数据线连接并信任本机
#   3) 至少用 Xcode 成功运行过一次（这样才会有 com.consynia.lumen 的描述文件）
# 用法：./Tools/install-ipad.sh [设备ID]
set -uo pipefail
cd "$(dirname "$0")/.."

TEAM="WZ6AS9TRW2"
SCHEME="Lumen-iOS"
BID="com.consynia.lumen"

pick_device() {
  xcrun devicectl list devices --json-output /tmp/lumen-devices.json >/dev/null 2>&1
  /usr/bin/python3 - <<'PY'
import json
try:
    d = json.load(open('/tmp/lumen-devices.json'))
except Exception:
    raise SystemExit(0)
devs = []
for dev in d.get('result', {}).get('devices', []):
    hw = dev.get('hardwareProperties', {})
    conn = dev.get('connectionProperties', {})
    if hw.get('platform') != 'iOS':
        continue
    if conn.get('tunnelState') != 'connected':
        continue
    devs.append((0 if 'iPad' in (hw.get('marketingName') or '') else 1, dev.get('identifier', '')))
for _, ident in sorted(devs):
    if ident:
        print(ident)
        break
PY
}

DEVICE_ID="${1:-}"
if [ -z "$DEVICE_ID" ]; then
  DEVICE_ID=$(pick_device)
fi

if [ -z "$DEVICE_ID" ]; then
  echo "没找到已连接的 iOS 设备（需要数据线连接并信任这台电脑）"
  xcrun devicectl list devices 2>/dev/null | sed -n '1,8p'
  exit 1
fi

echo "目标设备：$DEVICE_ID"

echo "编译（自动签名，用本机已有的托管描述文件）"
xcodebuild -project Lumen.xcodeproj -scheme "$SCHEME" -configuration Debug \
  -destination "platform=iOS,id=$DEVICE_ID" \
  DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic \
  build 2>&1 | tee /tmp/lumen-build.log | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | tail -6

# 描述文件缺失/失效时，再让 Xcode 联网补一次（需要账号在线）
if ! grep -q "BUILD SUCCEEDED" /tmp/lumen-build.log; then
  echo "首次失败，尝试联网更新描述文件…"
  xcodebuild -project Lumen.xcodeproj -scheme "$SCHEME" -configuration Debug \
    -destination "platform=iOS,id=$DEVICE_ID" -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM" CODE_SIGN_STYLE=Automatic \
    build 2>&1 | tee /tmp/lumen-build.log | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | tail -6
fi

if grep -qi "developer disk image could not be mounted" /tmp/lumen-build.log; then
  echo ""
  echo "设备连着但 DDI 挂不上：解锁 iPad 保持亮屏，或打开 Xcode → Window → Devices and Simulators 等它准备完"
  exit 5
fi

if grep -q "No Accounts" /tmp/lumen-build.log; then
  echo ""
  echo "Xcode 没有登录 Apple ID，且没有现成的描述文件："
  echo "  Xcode → Settings → Accounts → + → Apple ID"
  exit 3
fi

APP=$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/Lumen-*/Build/Products/Debug-iphoneos/Lumen.app 2>/dev/null | head -1)
if [ ! -d "$APP" ]; then
  echo "没找到构建产物，看 /tmp/lumen-build.log"
  exit 1
fi

echo "安装 $APP"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP" || exit 4

echo "启动"
xcrun devicectl device process launch --device "$DEVICE_ID" "$BID" || true

echo "完成。若提示「不受信任的开发者」：设置 → 通用 → VPN与设备管理 → 信任"
