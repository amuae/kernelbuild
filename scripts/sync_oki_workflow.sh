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
CCTV18_REPO="https://github.com/cctv18/android_kernel_common_oneplus_sm8650.git"
SOURCE_WORKFLOW="fastbuild_6.1.118.yml"
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

# 创建临时目录
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

echo -e "${YELLOW}[1/6] 从 cctv18 仓库下载最新工作流...${NC}"
# 使用 sparse checkout 只下载工作流文件
cd "$TEMP_DIR"
git init -q
git remote add origin "$CCTV18_REPO"
git config core.sparseCheckout true
echo ".github/workflows/$SOURCE_WORKFLOW" >> .git/info/sparse-checkout
git pull origin main --depth=1 -q

if [ ! -f ".github/workflows/$SOURCE_WORKFLOW" ]; then
    echo -e "${RED}错误: 无法找到源工作流文件${NC}"
    exit 1
fi

echo -e "${YELLOW}[2/6] 复制工作流到项目...${NC}"
cp ".github/workflows/$SOURCE_WORKFLOW" "$PROJECT_ROOT/$TARGET_WORKFLOW"
cd "$PROJECT_ROOT"

echo -e "${YELLOW}[3/6] 修改工作流名称...${NC}"
# 修改工作流名称
sed -i "s/^name:.*$/name: $WORKFLOW_NAME/" "$TARGET_WORKFLOW"

echo -e "${YELLOW}[4/6] 修改默认内核后缀...${NC}"
# 修改 KERNEL_NAME
sed -i "s/KERNEL_NAME: '.*'/KERNEL_NAME: '$KERNEL_NAME'/" "$TARGET_WORKFLOW"

echo -e "${YELLOW}[5/6] 修改伪装构建时间...${NC}"
# 修改 FAKESTAT 和 FAKETIME
sed -i "s/export FAKESTAT=\"[^\"]*\"/export FAKESTAT=\"$FAKE_DATE\"/" "$TARGET_WORKFLOW"
sed -i "s/export FAKETIME=\"@[^\"]*\"/export FAKETIME=\"@$FAKE_DATE\"/" "$TARGET_WORKFLOW"

echo -e "${YELLOW}[6/6] 移除自动创建 Release 并添加 Telegram 通知...${NC}"

# 使用 Python 进行复杂的文本处理（移除 release step 并添加 Telegram 通知）
python3 << 'PYTHON_SCRIPT'
import re
import sys

target_file = sys.argv[1] if len(sys.argv) > 1 else ".github/workflows/oki-6.1.118-fastbuild.yml"

with open(target_file, 'r', encoding='utf-8') as f:
    content = f.read()

# 移除 "创建发布" 步骤 (从 "- name: 创建发布" 到下一个 "- name:" 或 "# ==" 之前)
# 使用正则表达式匹配
pattern = r'''      - name: 创建发布
        id: create_release
        uses: softprops/action-gh-release@v1
        with:
          tag_name: .*?
          name: .*?
          body: \|.*?draft: false
          prerelease: false
          files: \|
            release_zips/AnyKernel3_\*\.zip

'''

# 替换为空（移除该步骤）
content = re.sub(pattern, '', content, flags=re.DOTALL)

# 检查是否已有 Telegram 通知
if '发送 Telegram 通知' not in content:
    # 在文件末尾添加 Telegram 通知步骤
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
            # 如果没有找到文件，只发送消息
            curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \\
              -d chat_id="${TELEGRAM_CHAT_ID}" \\
              -d text="${BUILD_INFO}" \\
              -d parse_mode="Markdown"
          fi
'''
    # 找到 release job 的最后一个步骤后添加
    if 'echo "KSU_TYPENAME=$KSU_TYPENAME"' in content:
        content = content.replace(
            'echo "KSU_TYPENAME=$KSU_TYPENAME" >> $GITHUB_ENV\n         \n      - name: 创建发布',
            'echo "KSU_TYPENAME=$KSU_TYPENAME" >> $GITHUB_ENV' + telegram_step
        )

with open(target_file, 'w', encoding='utf-8') as f:
    f.write(content)

print("工作流文件已更新")
PYTHON_SCRIPT

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}   同步完成！${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "已应用的修改:"
echo -e "  ${BLUE}•${NC} 工作流名称: ${GREEN}$WORKFLOW_NAME${NC}"
echo -e "  ${BLUE}•${NC} 内核后缀: ${GREEN}$KERNEL_NAME${NC}"
echo -e "  ${BLUE}•${NC} 伪装时间: ${GREEN}$FAKE_DATE${NC}"
echo -e "  ${BLUE}•${NC} 移除自动创建 Release"
echo -e "  ${BLUE}•${NC} 添加 Telegram 通知"
echo ""
echo -e "${YELLOW}如需提交更改，请运行:${NC}"
echo -e "  git add -A && git commit -m \"sync: update OKI workflow from cctv18\" && git push"
