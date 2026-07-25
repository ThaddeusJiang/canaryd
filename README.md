# mac_health

Mac 健康监控：过热/资源 + **软件"哑掉"检测**（进程活着但功能停摆，如 CleanClip 停止记录剪贴板）。

纯 Elixir/OTP 实现，零外部依赖，存储用 DETS。

## 三层健康模型

- **L1 系统层**：热节流（`pmset -g therm`）、load/核数、内存压力。连续 3 轮超标才通知。
- **L2 进程层**：CleanClip 进程存活，死了静默拉起。
- **L3 功能层**：合成探针 —— 写入剪贴板 → 等 4s → 检查 CleanClip 历史目录是否有新文件。

**空闲跳过**：键盘/鼠标 >30min 无操作（`ioreg HIDIdleTime`）时只记录 L1，跳过功能探针。

## 重启纪律

探针失败 → **静默自动重启**（不打扰用户），1 小时冷却防重启风暴；冷却期内连续 3 轮失败 → 标记 `blocked` 并发 macOS 通知（此时才打扰）。恢复自动记录 `recovered` 事件。

## 使用

```sh
mix escript.build          # 产出 ./mac_health
./mac_health check         # 跑一轮巡检（launchd 每 5 分钟自动执行）
./mac_health status        # 当前健康快照 + 最近事件
./mac_health history       # CleanClip 事件时间线
```

## 数据

`~/Library/Application Support/mac-health/`

- `state.dets` — 各目标最新状态机快照
- `events.dets` — 追加式事件日志（probe_fail / restarted / blocked / recovered / system_warn / skipped_idle）

## launchd

`com.thaddeusjiang.mac-health.plist` 已安装到 `~/Library/LaunchAgents/`，`StartInterval=300`。

重载：`launchctl bootout gui/$(id -u)/com.thaddeusjiang.mac-health && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.thaddeusjiang.mac-health.plist`

注意：重新 `mix escript.build` 后无需重装 plist（路径不变）。

## 测试

```sh
mix test   # 状态机转移逻辑
```
