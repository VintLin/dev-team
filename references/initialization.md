# 初始化设置

首次使用前需要配置的定时任务。

## 首次使用检查

首次使用 skill 时，系统会自动检查配置：

```bash
# 检查脚本可执行权限
ls -la scripts/*.sh

# 检查 tmux 是否可用
tmux -V
```

## Cron 任务配置

### 方式 1: 使用 OpenClaw Cron (推荐)

在 OpenClaw 配置中添加 cron 任务：

```yaml
# openclaw.yaml 或对应配置
cron:
  dev-team-monitor:
    schedule: "*/10 * * * *"  # 每 10 分钟
    command: scripts/check-agents.sh
    working-dir: /path/to/skills/dev-team
    
  dev-team-cleanup:
    schedule: "0 3 * * *"  # 每日凌晨 3 点
    command: scripts/cleanup-worktrees.sh
    working-dir: /path/to/skills/dev-team

  dev-team-prune-history:
    schedule: "10 3 * * *"  # 每日凌晨 3:10（可选，cleanup 已可自动触发）
    command: scripts/prune-history.sh --keep-days 7 --keep-count 50
    working-dir: /path/to/skills/dev-team
```

### 方式 2: 使用 macOS Cron

```bash
# 编辑 crontab
crontab -e

# 添加以下行
*/10 * * * * cd /path/to/skills/dev-team && ./scripts/check-agents.sh >> ./logs/cron.log 2>&1
0 3 * * * cd /path/to/skills/dev-team && ./scripts/cleanup-worktrees.sh >> ./logs/cleanup.log 2>&1
10 3 * * * cd /path/to/skills/dev-team && ./scripts/prune-history.sh --keep-days 7 --keep-count 50 >> ./logs/prune.log 2>&1
```

### 方式 3: 使用 LaunchDaemon (macOS 开机自启)

创建 `~/Library/LaunchAgents/com.dev-team.agent-check.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.dev-team.agent-check</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/path/to/skills/dev-team/scripts/check-agents.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>600</integer>
</dict>
</plist>
```

加载:
```bash
launchctl load ~/Library/LaunchAgents/com.dev-team.agent-check.plist
```

### 方式 4: 使用 OpenClaw Heartbeat (替代方案)

编辑 `HEARTBEAT.md` 添加检查任务：

```markdown
# HEARTBEAT.md

## 定期检查
- [ ] 运行 check-agents.sh
```

然后在 OpenClaw 配置中启用 heartbeat。

## 飞书通知

通知通过 OpenClaw 默认 channel 发送。检查脚本会：
1. 写入 `notifications.json`
2. OpenClaw 读取并通过飞书发送

## 日志位置

- 监控日志: `logs/cron.log`
- 清理日志: `logs/cleanup.log`
- 归档日志: `logs/prune.log`
- Agent 日志: `logs/`
- 通知队列: `notifications.json`
- 历史归档: `logs/archives/task-history-YYYY-MM.jsonl`

## 快速验证

```bash
# 测试监控脚本
./scripts/check-agents.sh

# 测试通知
# (OpenClaw 会自动读取 notifications.json)
```
