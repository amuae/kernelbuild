#!/bin/bash
# ============================================================================
# OKI 工作流同步脚本
# 用于从 cctv18 项目同步最新的 OKI 工作流并应用自定义修改
# ============================================================================

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 配置
SOURCE_URL="https://raw.githubusercontent.com/cctv18/oppo_oplus_realme_sm8650/refs/heads/main/.github/workflows/fastbuild_6.1.118.yml"
TARGET_WORKFLOW=".github/workflows/oki-6.1.118-fastbuild.yml"

# 自定义配置
WORKFLOW_NAME="构建 OKI 内核 6.1.118"
KERNEL_NAME="android14-11-o-g2b8edc801b38"
FAKE_DATE="2025-08-25 13:49:08"

# 脚本所在目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   OKI 工作流同步脚本${NC}"
echo -e "${BLUE}========================================${NC}"

# 切换到项目根目录
cd "$PROJECT_ROOT"

echo -e "${YELLOW}[1/5] 从 cctv18 仓库下载最新工作流...${NC}"
if ! curl -fsSL "$SOURCE_URL" -o "$TARGET_WORKFLOW"; then
    echo -e "${RED}错误: 无法下载源工作流文件${NC}"
    echo -e "${RED}URL: $SOURCE_URL${NC}"
    exit 1
fi
echo -e "${GREEN}下载成功!${NC}"

echo -e "${YELLOW}[2/5] 修改工作流名称...${NC}"
sed -i "s/^name:.*$/name: $WORKFLOW_NAME/" "$TARGET_WORKFLOW"

echo -e "${YELLOW}[3/5] 修改默认内核后缀...${NC}"
sed -i "s/KERNEL_NAME: '.*'/KERNEL_NAME: '$KERNEL_NAME'/" "$TARGET_WORKFLOW"

echo -e "${YELLOW}[4/5] 修改伪装构建时间...${NC}"
# 只修改定义 FAKESTAT/FAKETIME 的那两行，不替换 wrapper 脚本中的 '$FAKESTAT' 变量引用
sed -i '/echo.*\$FAKESTAT/!s/export FAKESTAT="[^"]*"/export FAKESTAT="'"$FAKE_DATE"'"/' "$TARGET_WORKFLOW"
sed -i '/echo.*\$FAKETIME/!s/export FAKETIME="@[^"]*"/export FAKETIME="@'"$FAKE_DATE"'"/' "$TARGET_WORKFLOW"

echo -e "${YELLOW}[5/5] 移除自动创建 Release 并添加 Telegram 通知...${NC}"

# 创建 Python 修改脚本
cat > /tmp/modify_oki_workflow.py << 'PYTHON_EOF'
import re
import sys

target_file = sys.argv[1]

with open(target_file, 'r', encoding='utf-8') as f:
    content = f.read()

# Telegram 通知步骤
telegram_step = '''
      # ==================== Telegram 通知 ====================
      - name: 发送 Telegram 通知
        if: success()
        env:
          TELEGRAM_BOT_TOKEN: ${{ secrets.TELEGRAM_BOT_TOKEN }}
          TELEGRAM_CHAT_ID: ${{ secrets.TELEGRAM_CHAT_ID }}
        run: |
          if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
            echo "Telegram 配置未设置，跳过通知"
            exit 0
          fi
          
          # KPM 状态文本
          if [[ "${{ github.event.inputs.kpm_enable }}" == "true" ]]; then
            KPM_STATUS="✅ 启用"
          else
            KPM_STATUS="❌ 禁用"
          fi
          
          # SUSFS 状态文本
          if [[ "${{ github.event.inputs.susfs_enable }}" == "true" ]]; then
            SUSFS_STATUS="✅ 启用"
          else
            SUSFS_STATUS="❌ 禁用"
          fi
          
          # 构建信息
          BUILD_INFO=$(cat << EOF
          🌽 *OKI 内核构建成功*
          
          📱 *机型*: 欧加真骁龙8Gen3通用
          🔢 *内核名*: ${{ env.KERNEL_VERSION }}.118-${{ env.KERNEL_NAME }}
          🕐 *内核时间*: ${{ env.FAKETIME }}
          🔧 *KernelSU*: ${{ env.KSU_TYPENAME }} (v${{ needs.build.outputs.ksuver }})
          🔒 *SUSFS*: ${SUSFS_STATUS}
          ⚡ *KPM*: ${KPM_STATUS}
          
          🔗 [查看 Actions](https://github.com/${{ github.repository }}/actions/runs/${{ github.run_id }})
          EOF
          )

          # 查找并发送 AnyKernel3 包
          ZIP_FILE=$(ls release_zips/AnyKernel3_*.zip 2>/dev/null | head -1)
          if [ -n "$ZIP_FILE" ]; then
            curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument" \\
              -F chat_id="${TELEGRAM_CHAT_ID}" \\
              -F document=@"$ZIP_FILE" \\
              -F caption="${BUILD_INFO}" \\
              -F parse_mode="Markdown"
          else
            curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \\
              -d chat_id="${TELEGRAM_CHAT_ID}" \\
              -d text="${BUILD_INFO}" \\
              -d parse_mode="Markdown"
          fi
'''

# 查找 "创建发布" 步骤的开始和结束位置
release_start = content.find('      - name: 创建发布')
if release_start != -1:
    # 找到 release_zips/AnyKernel3_*.zip 后的换行
    release_end = content.find('release_zips/AnyKernel3_*.zip', release_start)
    if release_end != -1:
        # 找到这行之后的换行符
        release_end = content.find('\n', release_end)
        if release_end != -1:
            release_end += 1  # 包含换行符
            # 删除整个 "创建发布" 步骤
            content = content[:release_start] + content[release_end:]
            print("已移除 '创建发布' 步骤")

# 检查是否已有 Telegram 通知
if '发送 Telegram 通知' not in content:
    # 在 KSU_TYPENAME 设置后添加 Telegram 步骤
    insert_marker = 'echo "KSU_TYPENAME=$KSU_TYPENAME" >> $GITHUB_ENV'
    insert_pos = content.find(insert_marker)
    if insert_pos != -1:
        # 找到这行结束的位置
        line_end = content.find('\n', insert_pos)
        if line_end != -1:
            content = content[:line_end+1] + telegram_step + content[line_end+1:]
            print("已添加 Telegram 通知步骤")
    else:
        print("警告: 未找到插入点，Telegram 通知未添加")
else:
    print("Telegram 通知已存在，跳过添加")

with open(target_file, 'w', encoding='utf-8') as f:
    f.write(content)

print("工作流文件已更新")
PYTHON_EOF

python3 /tmp/modify_oki_workflow.py "$TARGET_WORKFLOW"
rm -f /tmp/modify_oki_workflow.py

# 验证修改
echo ""
echo -e "${YELLOW}验证修改...${NC}"

ERRORS=0

if grep -q "$WORKFLOW_NAME" "$TARGET_WORKFLOW"; then
    echo -e "  ${GREEN}✓${NC} 工作流名称已修改"
else
    echo -e "  ${RED}✗${NC} 工作流名称修改失败"
    ERRORS=$((ERRORS+1))
fi

if grep -q "$KERNEL_NAME" "$TARGET_WORKFLOW"; then
    echo -e "  ${GREEN}✓${NC} 内核后缀已修改"
else
    echo -e "  ${RED}✗${NC} 内核后缀修改失败"
    ERRORS=$((ERRORS+1))
fi

if grep -q "$FAKE_DATE" "$TARGET_WORKFLOW"; then
    echo -e "  ${GREEN}✓${NC} 伪装时间已修改"
else
    echo -e "  ${RED}✗${NC} 伪装时间修改失败"
    ERRORS=$((ERRORS+1))
fi

if ! grep -q "创建发布" "$TARGET_WORKFLOW"; then
    echo -e "  ${GREEN}✓${NC} 已移除自动创建 Release"
else
    echo -e "  ${RED}✗${NC} 移除自动创建 Release 失败"
    ERRORS=$((ERRORS+1))
fi

if grep -q "发送 Telegram 通知" "$TARGET_WORKFLOW"; then
    echo -e "  ${GREEN}✓${NC} 已添加 Telegram 通知"
else
    echo -e "  ${RED}✗${NC} 添加 Telegram 通知失败"
    ERRORS=$((ERRORS+1))
fi

echo ""
if [ $ERRORS -eq 0 ]; then
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}   同步完成！所有修改验证通过${NC}"
    echo -e "${GREEN}========================================${NC}"
else
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}   同步完成，但有 $ERRORS 项验证失败${NC}"
    echo -e "${YELLOW}========================================${NC}"
fi

echo ""
echo -e "已应用的修改:"
echo -e "  ${BLUE}•${NC} 工作流名称: ${GREEN}$WORKFLOW_NAME${NC}"
echo -e "  ${BLUE}•${NC} 内核后缀: ${GREEN}$KERNEL_NAME${NC}"
echo -e "  ${BLUE}•${NC} 伪装时间: ${GREEN}$FAKE_DATE${NC}"
echo -e "  ${BLUE}•${NC} 移除自动创建 Release"
echo -e "  ${BLUE}•${NC} 添加 Telegram 通知"

# 自动提交更改
echo ""
echo -e "${YELLOW}[6/6] 提交更改到 Git...${NC}"

# 检查是否有更改
if git diff --quiet "$TARGET_WORKFLOW" 2>/dev/null; then
    echo -e "${GREEN}工作流文件无变化，无需提交${NC}"
else
    git add "$TARGET_WORKFLOW"
    COMMIT_MSG="sync: update OKI workflow from cctv18 ($(date '+%Y-%m-%d %H:%M:%S'))"
    git commit -m "$COMMIT_MSG"
    
    echo -e "${YELLOW}推送到远程仓库...${NC}"
    if git push; then
        echo -e "${GREEN}========================================${NC}"
        echo -e "${GREEN}   已成功推送到远程仓库!${NC}"
        echo -e "${GREEN}========================================${NC}"
    else
        echo -e "${RED}推送失败，请手动执行: git push${NC}"
    fi
fi
