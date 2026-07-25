# canaryd 🐤

> Canary in the coal mine for your Mac.

Mac 健康监控：过热/资源 + **软件"哑掉"检测**（进程活着但功能停摆，如 CleanClip 停止记录剪贴板）。
每次功能探针都是一只金丝雀：往系统里丢一个无害探子，它没活着回来，就说明环境出问题了。

纯 Elixir/OTP 实现，零外部依赖，存储用 DETS。

## 安装

```sh
mix escript.install hex canaryd
```

## 三层健康模型

- **L1 系统层**：热节流（`pmset -g therm`）、load/核数、内存压力。连续 3 轮超标才通知。
- **L2 进程层**：CleanClip 进程存活，死了静默拉起。
- **L3 功能层**：合成探针 —— 写入剪贴板 → 等 4s → 检查 CleanClip 历史目录是否有新文件。

**空闲跳过**：键盘/鼠标 >30min 无操作（`ioreg HIDIdleTime`）时只记录 L1，跳过功能探针。

## 重启纪律

探针失败 → **静默自动重启**（不打扰用户），1 小时冷却防重启风暴；冷却期内连续 3 轮失败 → 标记 `blocked` 并发 macOS 通知（此时才打扰）。恢复自动记录 `recovered` 事件。

## 使用

```sh
mix escript.build          # 产出 ./canaryd
./canaryd check         # 跑一轮巡检（launchd 每 5 分钟自动执行）
./canaryd status        # 当前健康快照 + 最近事件
./canaryd history       # CleanClip 事件时间线
```

## 数据

`~/Library/Application Support/canaryd/`

- `state.dets` — 各目标最新状态机快照
- `events.dets` — 追加式事件日志（probe_fail / restarted / blocked / recovered / system_warn / skipped_idle）

## launchd

`com.thaddeusjiang.canaryd.plist` 已安装到 `~/Library/LaunchAgents/`，`StartInterval=300`。

重载：`launchctl bootout gui/$(id -u)/com.thaddeusjiang.canaryd && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.thaddeusjiang.canaryd.plist`

注意：重新 `mix escript.build` 后无需重装 plist（路径不变）。

## 测试

```sh
mix test   # 状态机转移逻辑
```
