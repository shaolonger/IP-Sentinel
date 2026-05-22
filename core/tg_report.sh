#!/bin/bash

# ==========================================================
# 脚本名称: tg_report.sh (Telegram 每日战报模块 - 动态锚点版)
# 核心功能: 适配 Feature Flag 架构，按需展示独立统计数据，OTA 更新预警
# ==========================================================

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"
LOG_FILE="${INSTALL_DIR}/logs/sentinel.log"

# 1. 加载配置并自检
if [ ! -f "$CONFIG_FILE" ]; then exit 1; fi
source "$CONFIG_FILE"

DEFAULT_REPO_RAW_URL="https://raw.githubusercontent.com/shaolonger/IP-Sentinel/main"
LEGACY_REPO_RAW_URL="https://raw.githubusercontent.com/hotyue/IP-Sentinel/main"
REPO_RAW_URL="${REPO_RAW_URL:-$DEFAULT_REPO_RAW_URL}"
[ "$REPO_RAW_URL" = "$LEGACY_REPO_RAW_URL" ] && REPO_RAW_URL="$DEFAULT_REPO_RAW_URL"

if [ -z "$TG_TOKEN" ] || [ -z "$CHAT_ID" ]; then
    echo "⚠️ 未配置 Telegram 机器人参数，取消播报。"
    exit 0
fi

# ================== [v4.0.8 核心: 防并发风暴与 60 秒冷却机制] ==================
LOCK_FILE="${INSTALL_DIR}/core/.report_lock"
if [ -f "$LOCK_FILE" ]; then
    LAST_RUN=$(cat "$LOCK_FILE" 2>/dev/null)
    NOW=$(date +%s)
    # 校验 LAST_RUN 是否为有效数字，并比对 60 秒冷却期
    if [[ "$LAST_RUN" =~ ^[0-9]+$ ]]; then
        if [ $((NOW - LAST_RUN)) -lt 60 ]; then
            echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] [v${AGENT_VERSION:-未知}] [WARN ] [Report ] [SYSTEM] ⚠️ 战报请求过于频繁，触发 60 秒防并发风暴拦截。" >> "${INSTALL_DIR}/logs/sentinel.log"
            exit 0
        fi
    fi
fi
echo $(date +%s) > "$LOCK_FILE"
# ==============================================================================

# 2. 节点元数据抓取 (v3.2.2 协议自适应与多级容灾版)
# [v3.5.2 核心: 引入双轨身份架构]
if [ -z "$NODE_NAME" ]; then
    IP_HASH=$(echo "${PUBLIC_IP:-127.0.0.1}" | md5sum | cut -c 1-4 | tr 'a-z' 'A-Z')
    NODE_NAME="$(hostname | cut -c 1-10)-${IP_HASH}"
fi
NODE_ALIAS="${NODE_ALIAS:-$NODE_NAME}"

# --- [防线 1: 底层路由锁定与协议自适应] ---
CURL_BIND_OPT=""
DYNAMIC_IP_PREF="-${IP_PREF:-4}"

if [[ -n "$BIND_IP" && "$BIND_IP" =~ ^[0-9a-fA-F:\.]+$ ]]; then
    # [v3.6.3 容错层补丁] 探测物理网卡/虚拟 IP 存活状态
    RAW_BIND_IP=$(echo "$BIND_IP" | tr -d '[]')
    if ! ip addr show 2>/dev/null | grep -qw "$RAW_BIND_IP"; then
        CURL_BIND_OPT=""
    else
        CURL_BIND_OPT="--interface $BIND_IP"
        if [[ "$BIND_IP" == *":"* ]]; then
            DYNAMIC_IP_PREF="-6"
        elif [[ "$BIND_IP" == *"."* ]]; then
            DYNAMIC_IP_PREF="-4"
        fi
    fi
fi

# 多节点容灾探测出口 IP (注入协议自适应)
CURRENT_IP=$( (curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 api.ip.sb/ip || curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 ifconfig.me) 2>/dev/null | tr -d '[:space:]' )
# [v3.3.1 修改] 强制兜底：如果外部 API 挂了，优先使用固化的对外公网面孔 (兼容 NAT 机的空 BIND_IP)
[ -z "$CURRENT_IP" ] && CURRENT_IP="${PUBLIC_IP:-$BIND_IP}"

# 为可能获取到的 IPv6 自动添加方括号护甲
[[ "$CURRENT_IP" == *":"* ]] && [[ "$CURRENT_IP" != *"["* ]] && CURRENT_IP="[${CURRENT_IP}]"

# --- [防线 2: 多级 ISP 容灾探针链路] ---
ISP_INFO=""

# 探针 A: 纯文本 API (免 jq，极速稳定)
ISP_INFO=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 ipinfo.io/org 2>/dev/null)

# 探针 B: 备用纯文本 API
if [ -z "$ISP_INFO" ] || [[ "$ISP_INFO" == *"error"* ]]; then
    ISP_INFO=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 ip-api.com/line/?fields=isp 2>/dev/null)
fi

# 探针 C: 原版的 JSON API (需要 jq 兜底)
if [ -z "$ISP_INFO" ] || [[ "$ISP_INFO" == *"error"* ]]; then
    if command -v jq &> /dev/null; then
        ISP_INFO=$(curl $CURL_BIND_OPT $DYNAMIC_IP_PREF -s -m 5 api.ip.sb/geoip | jq -r '.organization' 2>/dev/null)
    fi
fi

# --- [防线 3: 数据清洗 (遵循底层共识原则)] ---
# 剔除 ipinfo 返回的开头 AS 号 (例如 "AS137535 JT TELECOM" -> "JT TELECOM")
ISP_INFO=$(echo "$ISP_INFO" | sed -E 's/^AS[0-9]+ //')

# 最终兜底判断
[ -z "$ISP_INFO" ] || [ "$ISP_INFO" == "null" ] && ISP_INFO="未知 ISP"

if [[ "$ISP_INFO" == *"Cloudflare"* ]]; then
    IP_TYPE="Cloudflare Warp 🛰️"
else
    IP_TYPE="$ISP_INFO 🏠"
fi

# 动态国旗 (与中枢全视界雷达对齐)
BASE_CC="${REGION_CODE%%-*}" # 兼容提取带有横杠的区域 (如 US-CA 提取为 US)
case "$BASE_CC" in
    US) FLAG="🇺🇸" ;; JP) FLAG="🇯🇵" ;; HK) FLAG="🇭🇰" ;; TW) FLAG="🇹🇼" ;; SG) FLAG="🇸🇬" ;;
    UK|GB) FLAG="🇬🇧" ;; DE) FLAG="🇩🇪" ;; FR) FLAG="🇫🇷" ;; NL) FLAG="🇳🇱" ;; CA) FLAG="🇨🇦" ;;
    AU) FLAG="🇦🇺" ;; KR) FLAG="🇰🇷" ;; IN) FLAG="🇮🇳" ;; BR) FLAG="🇧🇷" ;; RU) FLAG="🇷🇺" ;;
    CH) FLAG="🇨🇭" ;; SE) FLAG="🇸🇪" ;; NO) FLAG="🇳🇴" ;; DK) FLAG="🇩🇰" ;; FI) FLAG="🇫🇮" ;;
    IT) FLAG="🇮🇹" ;; ES) FLAG="🇪🇸" ;; PT) FLAG="🇵🇹" ;; IE) FLAG="🇮🇪" ;; PL) FLAG="🇵🇱" ;;
    AT) FLAG="🇦🇹" ;; BE) FLAG="🇧🇪" ;; TR) FLAG="🇹🇷" ;; ZA) FLAG="🇿🇦" ;; AE) FLAG="🇦🇪" ;;
    MY) FLAG="🇲🇾" ;; ID) FLAG="🇮🇩" ;; VN) FLAG="🇻🇳" ;; TH) FLAG="🇹🇭" ;; PH) FLAG="🇵🇭" ;;
    NZ) FLAG="🇳🇿" ;; AR) FLAG="🇦🇷" ;; CL) FLAG="🇨🇱" ;; MX) FLAG="🇲🇽" ;; IL) FLAG="🇮🇱" ;;
    SA) FLAG="🇸🇦" ;; EG) FLAG="🇪🇬" ;; NG) FLAG="🇳🇬" ;; KE) FLAG="🇰🇪" ;; RO) FLAG="🇷🇴" ;;
    BG) FLAG="🇧🇬" ;; CZ) FLAG="🇨🇿" ;; HU) FLAG="🇭🇺" ;; GR) FLAG="🇬🇷" ;; UA) FLAG="🇺🇦" ;;
    # === 补齐近期扩军的新增战区旗帜 ===
    MO) FLAG="🇲🇴" ;; KH) FLAG="🇰🇭" ;; MM) FLAG="🇲🇲" ;; LA) FLAG="🇱🇦" ;;
    MN) FLAG="🇲🇳" ;; NP) FLAG="🇳🇵" ;; BD) FLAG="🇧🇩" ;;
    *) FLAG="🌐" ;;
esac

# 3. 截取过去 24 小时的日志 (每天72次轮询，保留最新 1000 行足以覆盖单日战报)
LOG_CONTENT=$(tail -n 1000 "$LOG_FILE" 2>/dev/null)

if [ -z "$LOG_CONTENT" ]; then
    read -r -d '' MSG <<EOT
🛑 **[IP-Sentinel] 告警：节点异常**
----------------------------
📍 **节点名称**: \`${NODE_ALIAS}\`
⚠️ **警告**: 过去 24 小时无运行日志！
🛠️ **建议**: 节点可能刚部署完毕，请在面板手动执行一次养护动作。
EOT
else
    # ==========================================
    # 4. 动态模块数据分析 (核心升级)
    # ==========================================
    
    # 提取最近一次运行的快照 (智能识别所属模块)
    LAST_LOG_LINE=$(echo "$LOG_CONTENT" | grep "\[SCORE\]" | tail -n 1)
    LAST_TIME=$(echo "$LAST_LOG_LINE" | awk '{print $1,$2}' | tr -d '[]')
    LAST_MOD=$(echo "$LAST_LOG_LINE" | awk '{print $4}' | tr -d '[]')
    LAST_SCORE=$(echo "$LAST_LOG_LINE" | awk -F'自检结论: ' '{print $2}')

    # 开始组装战报头部
    MSG="📊 **IP-Sentinel 每日简报 (${FLAG} ${REGION_NAME})**
----------------------------
📍 **节点名称**: \`${NODE_ALIAS}\`
📡 **出口 IP**: \`${CURRENT_IP}\`
🛡️ **IP 属性**: ${IP_TYPE}"

    # --- [分析块 1: Google 纠偏模块] ---
    if [ "$ENABLE_GOOGLE" == "true" ]; then
        GOOGLE_LOGS=$(echo "$LOG_CONTENT" | grep "\[Google")
        G_TOTAL=$(echo "$GOOGLE_LOGS" | grep "\[START\]" -c)
        G_SUCCESS=$(echo "$GOOGLE_LOGS" | grep "✅" -c)
        G_FAILED=$(echo "$GOOGLE_LOGS" | grep "❌" -c)
        G_WARN=$(echo "$GOOGLE_LOGS" | grep "⚠️" -c)
        
        G_RATE="0.0"
        [ "$G_TOTAL" -gt 0 ] && G_RATE=$(awk "BEGIN {printf \"%.1f\", ($G_SUCCESS/$G_TOTAL)*100}")

        MSG="$MSG

🎯 **[Google 区域纠偏]**
🚀 执行总数: ${G_TOTAL} 次 (胜率: **${G_RATE}%**)
✅ 成功: ${G_SUCCESS} | ❌ 送中: ${G_FAILED} | ⚠️ 警告: ${G_WARN}"
    fi

    # --- [分析块 2: IP 信用净化模块] ---
    if [ "$ENABLE_TRUST" == "true" ]; then
        TRUST_LOGS=$(echo "$LOG_CONTENT" | grep "\[Trust")
        T_TOTAL=$(echo "$TRUST_LOGS" | grep "\[START\]" -c)
        T_SUCCESS=$(echo "$TRUST_LOGS" | grep "✅" -c)
        T_FAILED=$(echo "$TRUST_LOGS" | grep "❌" -c)
        
        T_RATE="0.0"
        [ "$T_TOTAL" -gt 0 ] && T_RATE=$(awk "BEGIN {printf \"%.1f\", ($T_SUCCESS/$T_TOTAL)*100}")

        MSG="$MSG

🔰 **[IP 信用净化]**
🚀 净化总数: ${T_TOTAL} 轮 (成功率: **${T_RATE}%**)
✅ 成功注入: ${T_SUCCESS} | ❌ 访问受阻: ${T_FAILED}"
    fi

    # 组装战报尾部 (最近快照)
    MSG="$MSG

🕒 **最近执行快照: [${LAST_MOD:-"System"}]**
时间: ${LAST_TIME:-"暂无数据"} (节点本地)
结论: ${LAST_SCORE:-"暂无数据"}"

fi

# ==========================================
# 5. [核心: OTA 云端版本探针与告警模块]
# ==========================================
# 从配置文件提取当前本地版本，若无则默认为未知
LOCAL_VER="${AGENT_VERSION:-未知}"
# [时区对齐] 强制获取当前绝对 UTC 时间，作为全局统一的战报落款
REPORT_UTC_TIME=$(date -u "+%Y-%m-%d %H:%M:%S UTC")

# 极轻量级探针: 抓取 GitHub 云端的 version.txt (超时 3 秒，KV解析法)
REMOTE_VER=$(curl -s -m 3 "${REPO_RAW_URL}/version.txt" | grep "^AGENT_VERSION=" | cut -d'=' -f2 | tr -d '[:space:]')

# 构建底部引擎状态块
MSG="$MSG
----------------------------
🛡️ **系统引擎状态**
⏱️ 战报生成: \`${REPORT_UTC_TIME}\`
当前运行版本: \`v${LOCAL_VER}\`"

# 比准逻辑：如果成功抓到了远端版本，且和本地不一样
if [ -n "$REMOTE_VER" ] && [ "$REMOTE_VER" != "$LOCAL_VER" ]; then
    MSG="$MSG
最新官方版本: \`v${REMOTE_VER}\` (✨有新版)
💡 *系统提示：检测到新版引擎，建议通过控制台执行 OTA 热更新！*"
elif [ -n "$REMOTE_VER" ] && [ "$REMOTE_VER" == "$LOCAL_VER" ]; then
    MSG="$MSG
最新官方版本: \`v${REMOTE_VER}\` (✅已是最新)
💡 *IP-Sentinel 持续为您守护节点。*
*若本项目对您有帮助，欢迎前往 GitHub 赐予 🌟*"
else
    # 抓取失败兜底
    MSG="$MSG
💡 *IP-Sentinel 持续为您守护节点。*
*若本项目对您有帮助，欢迎前往 GitHub 赐予 🌟*"
fi

# 5. 调用 API 推送 (接入安全网关，挂载交互式控制台按钮)
JSON_PAYLOAD=$(jq -n \
  --arg cid "$CHAT_ID" \
  --arg txt "$MSG" \
  --arg cb "manage:${NODE_NAME}" \
  '{
    chat_id: $cid,
    text: $txt,
    parse_mode: "Markdown",
    disable_web_page_preview: true,
    reply_markup: {
      inline_keyboard: [[{"text": "⚙️ 调出该节点控制台", "callback_data": $cb}]]
    }
  }')

RESPONSE=$(curl -s -m 10 -X POST "${TG_API_URL}" \
    -H "Content-Type: application/json" \
    -d "$JSON_PAYLOAD")

if [[ "$RESPONSE" != *"\"ok\":true"* ]]; then
    echo "❌ 战报发送失败！API 响应: $RESPONSE" >> "${INSTALL_DIR}/logs/error.log"
else
    echo "✅ 战报推送成功！"
fi