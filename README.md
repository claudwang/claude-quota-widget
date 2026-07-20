# Claude 额度悬浮窗 · Claude Quota Widget

一个 Windows 桌面悬浮小窗，实时显示 Claude Code（Pro / Max 订阅）的额度使用情况。零依赖，纯 PowerShell + WPF，下载即用。

> A tiny always-on-top Windows desktop widget showing your Claude Code rate-limit usage (5-hour window / weekly / per-model weekly) in real time. Pure PowerShell + WPF, zero dependencies.

## 它长什么样

![悬浮窗截图](screenshot.png)

- 额度行**按官方接口实际返回的维度动态生成**（含按模型细分的每周额度），官方新增维度自动支持
- 进度条颜色随用量变化：绿（<50%）→ 黄（50–80%）→ 红（>80%）
- 点击行标题**折叠/展开**该行；点 ─ **最小化成小胶囊**（只剩 `Claude 33%`）
- 窗口位置、折叠状态、胶囊状态都会记住；靠屏幕边缘时朝反方向智能展开，不会跑出屏幕

## 快速开始

**要求**：Windows 10/11、Windows PowerShell 5.1（系统自带）、Claude Pro 或 Max 订阅。

1. **下载**：`git clone` 本仓库，或 Download ZIP 解压到任意目录（路径不要带中文以防万一）。

2. **一次性登录**（让小工具能调用官方用量接口）。在 PowerShell 里运行：

   ```powershell
   claude auth login
   ```

   > 只用 Claude Code **桌面版**、没装 CLI 的用户，用应用自带的 CLI 登录：
   > ```powershell
   > & (Get-ChildItem "$env:APPDATA\Claude\claude-code\*\claude.exe" | Sort-Object Name -Descending | Select-Object -First 1) auth login --claudeai
   > ```

3. **启动**：双击 `launch.vbs`。悬浮窗出现在屏幕右上角，一分钟内显示真实额度。

### 可选配置

**随 Claude Code 自动启动**（推荐）：在 `~/.claude/settings.json` 里加 SessionStart 钩子（把路径换成你的解压目录）：

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "wscript.exe",
            "args": ["C:\\你的路径\\claude-quota-widget\\launch.vbs"],
            "async": true
          }
        ]
      }
    ]
  }
}
```

已在运行时重复启动会被单实例锁静默跳过，放心配置。

**终端 CLI 用户的零请求通道**：如果你在终端里用 Claude Code，可以把 `statusline.ps1` 配置为 statusline——它会把额度数据实时写到本地文件，悬浮窗优先读文件、完全不发网络请求，顺便你还得到一条 `模型 | 5h x% | 7d x% | ctx x%` 状态栏：

```json
{
  "statusLine": {
    "type": "command",
    "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:/你的路径/claude-quota-widget/statusline.ps1\"",
    "refreshInterval": 60
  }
}
```

（Claude Code 桌面版不执行 statusline，桌面版用户跳过这段。）

**开机常驻**：运行一次 `install-autostart.ps1`；取消则删除 `shell:startup` 里的 `ClaudeQuotaWidget.lnk`。

## 操作一览

| 操作 | 方法 |
|------|------|
| 移动 | 按住悬浮窗任意位置拖动 |
| 折叠某行 | 点击行标题，再点展开 |
| 最小化 | 点 ─ 收成胶囊；点胶囊恢复（胶囊可拖动，悬停显示数据时间） |
| 手动刷新 | 点 ⟳ |
| 关闭 | 点 ✕ |

## 工作原理与隐私

```
~/.claude/quota-live.json（statusline 喂数，若有，零网络请求）
        ↓ 悬浮窗每 5 秒读取
QuotaWidget.ps1（WPF 悬浮窗）
        ↓ 文件超过 2 分钟未更新时
官方用量接口 api.anthropic.com/api/oauth/usage（每 5 分钟一次）
```

- 登录凭据只从本机 `~/.claude/.credentials.json` 读取，只发送给 Anthropic 官方域名（`api.anthropic.com` / `console.anthropic.com`），令牌过期自动续期并写回。**不经过任何第三方服务器，不采集不上传任何数据。**
- 显示的百分比与 Claude Code 内 `/usage` 页面同源。

## 常见问题

- **显示"需要一次性登录"** → 完成上面第 2 步。
- **显示"登录已失效"** → 重新 `claude auth login` 一次。
- **显示"接口限流"** → 会自动退避重试，期间显示最后一次数据并标注时间。
- **和 `/usage` 页面差 1%** → 刷新时间差 + 取整方式差异，正常。
- **中文乱码 / 脚本报错** → `QuotaWidget.ps1` 必须保持 **UTF-8 with BOM** 编码（Git 下载不会有此问题，手动编辑时注意）。
- **修改脚本后不生效** → 关闭悬浮窗重新双击 `launch.vbs`。

## 文件清单

| 文件 | 作用 |
|------|------|
| `QuotaWidget.ps1` | 悬浮窗主程序 |
| `statusline.ps1` | （可选）CLI statusline 喂数脚本 |
| `launch.vbs` | 无窗口启动器 |
| `install-autostart.ps1` | （可选）开机自启安装 |

## 免责声明

非官方工具，与 Anthropic 无关。额度数据来自 Claude Code 官方客户端使用的接口，该接口未公开文档化，随官方变更可能失效。仅供个人查看自己账户的用量。

## License

MIT
