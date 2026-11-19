# 05 systemd 服务

> 实验日期：2026-10-28
> 环境：Ubuntu 24.04.5 LTS（`ubuntulearn` / `192.168.9.128`），**systemd 255 (255.4-1ubuntu8.18)**
> 快照：`lab-05-开始`

---

## 一、目标与验收

**做：** 写一个 Python 或 Shell 脚本 → 包成 `.service` → 设开机自启 → 失败自动重启 → 日志进 journal

**验收：** `systemctl enable --now` 后能跑；`kill` 掉进程后 5 秒内自动拉起

**本次结论：** 全部达成。实测 `kill -9` 后 **3 秒**恢复；重启机器后 `NRestarts=0`、`Active since` = 开机时间；另做了"启动即崩溃"的闸门演示。

---

## 二、最终成果

```
/usr/local/bin/lab05-heartbeat.sh              可执行脚本（前台死循环）
/etc/systemd/system/lab05-heartbeat.service    单元文件
/etc/systemd/system/multi-user.target.wants/lab05-heartbeat.service -> ...   （enable 建的软链）
```

**unit 文件全文：**

```ini
[Unit]
Description=Lab05 Heartbeat Demo
Documentation=file:/usr/local/bin/lab05-heartbeat.sh
After=network.target

[Service]
Type=simple
User=madrough
ExecStart=/usr/local/bin/lab05-heartbeat.sh
Restart=always
RestartSec=3
TimeoutStopSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

**脚本全文：**

```bash
#!/bin/bash
while true; do
  echo "[$(date '+%F %T')] lab05 heartbeat pid=$$"
  sleep 2
done
```

---

## 三、实测数据

| 阶段 | 结果 |
|---|---|
| 首次启动 | `Active: active (running)`，`Main PID 2740`，`Tasks 2`（bash + sleep），`Memory 564K` |
| 第 1 次 `kill -9` | `03:39:42` 被杀 → `03:39:45` 重启 = **3 秒**，`restart counter is at 1`，新 PID 3165 |
| 第 2 次 `kill -9` | `03:42:37` → `03:42:40` = **3 秒**，`NRestarts=2` |
| 重启机器后 | `Active since 03:48:00`（= 开机时间）、`Main PID 1433`（小号 PID = 开机早期启动）、`NRestarts 0`、`enabled` + `active` |
| 崩溃演示 | `04:06:51`~`04:06:57` 连崩 5 次（counter 1→5），第 6 次 `Start request repeated too quickly.`，闸门落下 |

**三个关键数字：**

- `RestartSec=3` → 实测 **3 秒**恢复（满足 5 秒内）
- `StartLimitBurst=5` / `StartLimitIntervalUSec=10s` → **10 秒内崩 5 次就放弃**
- `Main PID 1433`（重启后）vs `2740`（手动启动）→ 小号 PID 说明是开机早期启动的

---

## 四、操作步骤

> 约定：每个命令块标注执行身份。

### 4.1 先摸清 systemd 与目录约定

```bash
# 身份：madrough
madrough@ubuntulearn:~$ systemctl --version | head -1
madrough@ubuntulearn:~$ ls /etc/systemd/system/
madrough@ubuntulearn:~$ cat /lib/systemd/system/cron.service
```

**三个 unit 目录的分工：**

| 目录 | 谁放的 | 说明 |
|---|---|---|
| `/lib/systemd/system/` | 软件包 | 系统自带，**升级会被覆盖，别改** |
| `/etc/systemd/system/` | 管理员 | 自建单元 / 覆盖默认，**优先级最高** |
| `/run/systemd/system/` | 运行时 | 重启即消失 |

### 4.2 写脚本（先独立跑通）

```bash
# 身份：madrough
madrough@ubuntulearn:~$ sudo tee /usr/local/bin/lab05-heartbeat.sh > /dev/null <<'EOF'
#!/bin/bash
while true; do
  echo "[$(date '+%F %T')] lab05 heartbeat pid=$$"
  sleep 2
done
EOF
madrough@ubuntulearn:~$ sudo chmod +x /usr/local/bin/lab05-heartbeat.sh
madrough@ubuntulearn:~$ timeout 7 /usr/local/bin/lab05-heartbeat.sh
```

**两个关键点：**

1. **heredoc 的 `'EOF'` 必须带引号**——不带引号的话 `$(date ...)` 和 `$$` 会在**创建文件时**就被展开，文件里会写死一个固定时间戳
2. **脚本必须是"前台持续运行"**——自己不要 fork 到后台，后台化交给 systemd

`timeout 7` = 最多跑 7 秒自动 `SIGTERM`，用来测试死循环脚本，省得手工 `Ctrl+C`。

### 4.3 写 unit 文件

```bash
# 身份：madrough
madrough@ubuntulearn:~$ sudo tee /etc/systemd/system/lab05-heartbeat.service > /dev/null <<'EOF'
[Unit]
Description=Lab05 Heartbeat Demo
Documentation=file:/usr/local/bin/lab05-heartbeat.sh
After=network.target

[Service]
Type=simple
User=madrough
ExecStart=/usr/local/bin/lab05-heartbeat.sh
Restart=always
RestartSec=3
TimeoutStopSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
madrough@ubuntulearn:~$ sudo systemd-analyze verify /etc/systemd/system/lab05-heartbeat.service
```

**`systemd-analyze verify` 无输出 = 语法通过。** 启动前先验证，省得在 `status` 里读一堆报错。

### 4.4 启动并设为自启

```bash
# 身份：madrough
madrough@ubuntulearn:~$ sudo systemctl daemon-reload
madrough@ubuntulearn:~$ sudo systemctl enable --now lab05-heartbeat.service
madrough@ubuntulearn:~$ systemctl status lab05-heartbeat --no-pager
madrough@ubuntulearn:~$ sudo journalctl -u lab05-heartbeat -n 10 --no-pager
martrough@ubuntulearn:~$ sudo journalctl -u lab05-heartbeat -f     # 实时跟随，Ctrl+C 退出
```

实测 `status`：

```
● lab05-heartbeat.service - Lab05 Heartbeat Demo
     Loaded: loaded (/etc/systemd/system/lab05-heartbeat.service; enabled; preset: enabled)
     Active: active (running) since Sat 2026-10-31 03:33:11 UTC; 59s ago
   Main PID: 2740 (lab05-heartbeat)
      Tasks: 2 (limit: 4543)
     Memory: 564.0K (peak: 1.0M)
        CPU: 120ms
     CGroup: /system.slice/lab05-heartbeat.service
             ├─2740 /bin/bash /usr/local/bin/lab05-heartbeat.sh
             └─2800 sleep 2
```

**`CGroup` 树很重要**：服务和它的子进程都在同一棵 cgroup 上，systemd 杀服务时会整棵树一起处理，不会留孤儿进程。

### 4.5 验证自启软链

```bash
# 身份：madrough
madrough@ubuntulearn:~$ ls -l /etc/systemd/system/multi-user.target.wants/lab05-heartbeat.service
madrough@ubuntulearn:~$ systemctl is-enabled lab05-heartbeat
madrough@ubuntulearn:~$ systemctl is-active lab05-heartbeat
```

期望：软链 `->` 指向 unit 文件；输出 `enabled`、`active`。

### 4.6 kill -9 测试自动拉起

```bash
# 身份：madrough
madrough@ubuntulearn:~$ P=$(systemctl show -p MainPID --value lab05-heartbeat); sudo kill -9 $P
madrough@ubuntulearn:~$ sleep 6; systemctl status lab05-heartbeat --no-pager | head -8
madrough@ubuntulearn:~$ systemctl show -p NRestarts --value lab05-heartbeat
madrough@ubuntulearn:~$ sudo journalctl -u lab05-heartbeat --since "15 min ago" --no-pager | grep -Ei "exited|Scheduled|Started|Failed"
```

实测日志：

```
03:39:42 lab05-heartbeat.service: Main process exited, code=killed, status=9/KILL
03:39:42 lab05-heartbeat.service: Failed with result 'signal'.
03:39:45 lab05-heartbeat.service: Scheduled restart job, restart counter is at 1.
03:39:45 lab05-heartbeat.service: Started lab05-heartbeat.service - Lab05 Heartbeat Demo.
```

**`03:39:42` → `03:39:45` = 3 秒。**

**算精确时间的方法**：用 `-o short-unix` 拿到 Unix 时间戳再相减：

```bash
sudo journalctl -u lab05-heartbeat --since "15 min ago" -o short-unix --no-pager | grep -E "Main process exited|Started"
```

### 4.7 重启机器验证开机自启

```bash
# 身份：madrough
madrough@ubuntulearn:~$ sudo reboot
```

重连后：

```bash
# 身份：madrough
madrough@ubuntulearn:~$ systemctl status lab05-heartbeat --no-pager | head -8
madrough@ubuntulearn:~$ systemctl is-enabled lab05-heartbeat; systemctl is-active lab05-heartbeat; systemctl show -p NRestarts --value lab05-heartbeat
madrough@ubuntulearn:~$ sudo journalctl -b -u lab05-heartbeat -n 6 --no-pager
madrough@ubuntulearn:~$ systemd-analyze blame | head -8
```

**判断依据**：`Active since` ≈ 开机时间、`Main PID` 号很小、`NRestarts=0`（是开机正常启动，不是崩溃重启）。

### 4.8 崩溃闸门演示

```bash
# 身份：madrough
madrough@ubuntulearn:~$ sudo tee /etc/systemd/system/lab05-crash.service > /dev/null <<'EOF'
[Unit]
Description=Lab05 Crash Loop Demo

[Service]
Type=simple
ExecStart=/bin/false
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
EOF
madrough@ubuntulearn:~$ sudo systemctl daemon-reload
madrough@ubuntulearn:~$ sudo systemctl start lab05-crash.service
madrough@ubuntulearn:~$ sleep 15; systemctl status lab05-crash --no-pager | head -10
madrough@ubuntulearn:~$ sudo journalctl -u lab05-crash --no-pager | tail -25
madrough@ubuntulearn:~$ systemctl show -p StartLimitBurst -p StartLimitIntervalUSec lab05-crash
```

实测日志（连崩 5 次后被拦）：

```
04:06:51 Started ... / Main process exited, code=exited, status=1/FAILURE / Failed with result 'exit-code'
04:06:52 Scheduled restart job, restart counter is at 1.
...
04:06:57 Scheduled restart job, restart counter is at 5.
04:06:57 lab05-crash.service: Start request repeated too quickly.
04:06:57 Failed to start lab05-crash.service
```

实测阈值：

```
StartLimitIntervalUSec=10s
StartLimitBurst=5
```

> **显示差异**：systemd 255 里 `Active` 显示 `failed (Result: exit-code)` 而不是旧版的 `start-limit-hit`。**权威证据是日志里那句 `Start request repeated too quickly.`**

**恢复与清理：**

```bash
# 身份：madrough
madrough@ubuntulearn:~$ sudo systemctl reset-failed lab05-crash      # 清失败计数
madrough@ubuntulearn:~$ sudo systemctl stop lab05-crash.service
madrough@ubuntulearn:~$ sudo rm /etc/systemd/system/lab05-crash.service
madrough@ubuntulearn:~$ sudo systemctl daemon-reload
madrough@ubuntulearn:~$ sudo systemctl reset-failed
```

---

## 五、unit 文件字段详解

### 5.1 三段职责

| 段 | 管什么 | 记忆 |
|---|---|---|
| `[Unit]` | 元信息 + 依赖/顺序：我是谁、和谁有关系 | 名片和关系 |
| `[Service]` | 怎么运行进程：命令、身份、挂了怎么办 | 干活说明书 |
| `[Install]` | 怎么被"启用"：enable 时挂到哪 | 挂到哪根绳子上 |

### 5.2 `[Unit]` 段

| 字段 | 含义 |
|---|---|
| `Description` | 人看的描述，`status` 里显示 |
| `Documentation` | 文档位置，`man:xxx(8)` / `file:` / URL |
| `After=` | **启动顺序**：排在这些单元之后（不要求它们成功） |
| `Before=` | 排在这些单元之前 |
| `Requires=` | **强依赖**：对方失败我也失败 |
| `Wants=` | **弱依赖**：对方失败我照常启动 |
| `StartLimitIntervalSec` / `StartLimitBurst` | 重启闸门（见 5.5） |

> **`After` / `Requires` / `Wants` 三者的区别是最常考的点**：
> - `After` 只管**顺序**，不管依赖
> - `Requires` 管**依赖**，对方挂了我也挂
> - `Wants` 管**软依赖**，对方挂了不管我
>
> 真实场景：连数据库的服务，"数据库先起"用 `After`，"数据库必须能用"用 `Requires`。

### 5.3 `[Service]` 段的 `Type`

| Type | systemd 怎么判断"启动成功" | 适用 |
|---|---|---|
| `simple`（默认） | `ExecStart` 的进程**就是**主进程，立刻算成功 | 前台持续运行的程序 |
| `forking` | 进程 fork 后**父进程退出**，留下的子进程是主进程 | 传统守护进程（nginx 默认） |
| `oneshot` | 进程**跑完退出**才算完成，期间是 `activating` | 一次性任务 |
| `notify` | 进程调 `sd_notify()` 主动报告就绪 | 需精确就绪点 |
| `idle` | 等所有任务启动完再起 | 控制台输出类 |
| `exec` | 类似 simple，但等 `execve()` 成功后才算启动 | 更严格的 simple |

**选错的后果：**

- 前台死循环写成 `forking` → systemd 等父进程退出，等 `TimeoutStartSec`（默认 90 秒）超时 → 标记 failed
- 一次性任务写成 `simple` → systemd 以为它一直在跑，其实早退出了（不跟踪进程存活）
- 一次性任务忘记 `oneshot` → `is-active` 状态会误导

### 5.4 `Restart` 与 `RestartSec`

| `Restart=` | 正常退出（exit 0） | 非 0 退出 / 被信号杀 |
|---|---|---|
| `no`（默认） | 不重启 | 不重启 |
| `always` | **重启** | **重启** |
| `on-failure` | 不重启 | **重启** |
| `on-abnormal` | 不重启 | 被信号杀 / 超时才重启 |
| `on-success` | 重启 | 不重启 |

**`kill -9` 属于"被信号杀死"，`always` 和 `on-failure` 都能触发重启。** 区别只在"正常退出"。

**`RestartSec` 与"5 秒内恢复"的约束：**

```
实际恢复时间 = RestartSec + systemd 调度开销（几十~几百毫秒）
```

| `RestartSec` | 实际 | 能否过"5 秒内" |
|---|---|---|
| `1` | ~1.0s | ✅ |
| `3` | ~3.0s | ✅ 本次采用 |
| `4` | ~4.0s | ⚠️ 卡边 |
| `5` | ~5.0s+ | ❌ 会超 |

**结论：`RestartSec` 必须 < 5，建议 ≤ 3。**

也不能太小（如 `0.1`），否则崩溃时会疯狂重启 —— 这正是需要闸门的原因。

### 5.5 重启闸门

```ini
[Unit]
StartLimitIntervalSec=10     # 统计窗口
StartLimitBurst=5            # 窗口内最多启动次数
```

超过阈值 → `Start request repeated too quickly.` → 停止重试，单元保持 failed。

**默认值就是 `10s` / `5 次`**（由 `/etc/systemd/system.conf` 的 `DefaultStartLimitIntervalSec` / `DefaultStartLimitBurst` 决定）。

**为什么需要它**：配置写错导致启动即崩时，没有闸门会每秒重启一次，把 CPU 和日志磁盘打爆。真实案例：某服务配错 + `Restart=always`，一夜 journal 涨 40G 把根分区撑满。

**闸门落下后光改配置不够**，必须清计数：

```bash
sudo systemctl reset-failed <单元名>
```

### 5.6 其他常用字段

| 字段 | 含义 |
|---|---|
| `User=` / `Group=` | 以指定用户/组运行（**不写就是 root**） |
| `WorkingDirectory=` | 工作目录 |
| `Environment=` / `EnvironmentFile=` | 环境变量 |
| `ExecStartPre=` / `ExecStartPost=` | 启动前/后执行的辅助命令 |
| `ExecStop=` | 自定义停止命令 |
| `TimeoutStartSec=` / `TimeoutStopSec=` | 启动/停止超时（默认 90s） |
| `StandardOutput=` / `StandardError=` | `journal` / `file:` / `null` / `tty` |
| `KillMode=` | `control-group`（默认，杀整棵树）/ `process` / `mixed` / `none` |
| `KillSignal=` | 停止时先发什么信号（默认 `SIGTERM`） |
| `WantedBy=` | 被哪个 target 想要（决定 enable 挂到哪） |
| `RestartPreventExitStatus=` | 这些退出码不触发重启 |

---

## 六、原理

### 6.1 `enable` 到底做了什么

`systemctl enable lab05-heartbeat` 的唯一实质动作：

```bash
ln -s /etc/systemd/system/lab05-heartbeat.service \
      /etc/systemd/system/multi-user.target.wants/lab05-heartbeat.service
```

**开机时 systemd 要达成 `multi-user.target`，就去启动该 target 的 `.wants/` 和 `.requires/` 目录下所有单元。软链存在 = 会被拉起。**

| 目录 | 语义 |
|---|---|
| `xxx.target.wants/` | 弱依赖（启动它，失败不影响 target） |
| `xxx.target.requires/` | 强依赖（失败则 target 也失败） |

**没有魔法，就是一个软链。**

### 6.2 `enable` / `start` 是两个正交维度

| 命令 | 现在启动 | 开机自启 |
|---|---|---|
| `start X` | ✅ | ❌ |
| `enable X` | ❌ | ✅ |
| `enable --now X` | ✅ | ✅ |
| `stop X` | 停止 | 自启设置**保留** |
| `disable X` | 不影响运行中的 | 取消自启 |
| `restart X` | 重启 | 不变 |
| `reload X` | 让服务重读**自己的**配置（`ExecReload`），不重启进程 | 不变 |

> `restart`（重启进程）和 `reload`（进程不退出，重读配置）是两回事，别混。

### 6.3 为什么必须 `daemon-reload`

systemd 在启动时把**所有 unit 文件解析成内存对象**。改磁盘文件它不知道。

```
改文件 →（systemd 内存里仍是旧配置）→ start 用的还是旧的
```

`daemon-reload` 让它重新扫描并解析所有 unit。

| 情况 | 不 reload 的表现 |
|---|---|
| 新增单元 | `Unit xxx.service not found.` |
| 改了 `ExecStart` | 还跑旧命令，误以为没生效 |
| 改了 `Restart` | 策略不生效 |

**这和 03 里改 `fstab` 后必须 `daemon-reload` 是同一个机制**——fstab 也会被编译成 `.mount` 单元。

### 6.4 cgroup 与 `KillMode`

systemd 给每个服务建一个 cgroup，服务的所有子进程都在里面（`status` 的 `CGroup` 树可见）。

`KillMode=control-group`（默认）停止服务时**杀掉 cgroup 里所有进程**；`process` 只杀主进程（子进程会变孤儿）。这也是 systemd 比传统 init 脚本强的地方——不会留野进程。

### 6.5 journald 接管日志

`StandardOutput=journal` 后，脚本 `echo` 的内容直接进 journald，由它负责收集、按单元索引、轮转。省去自己写日志文件、自己管轮转的麻烦。

---

## 七、踩坑清单

| # | 坑 | 正确做法 |
|---|---|---|
| 1 | heredoc 用了 `<<EOF` 不带引号 | `<<'EOF'` 才不展开 `$(...)` 和 `$$`，否则写进文件的是固定值 |
| 2 | 脚本里自己 fork 到后台（`&`、`nohup`） | 后台化交给 systemd，脚本必须前台死循环 |
| 3 | 忘了 `daemon-reload` | 新增/改 unit 必须先 reload，否则 not found 或用旧配置 |
| 4 | 以为 `enable` 会立刻启动 | `enable` 只建软链；要现在跑用 `enable --now` |
| 5 | `Type` 选错 | 前台程序用 `simple`，传统守护进程用 `forking`，一次性用 `oneshot` |
| 6 | `RestartSec` 设 5 或更大，验收不过 | 必须 < 5，建议 ≤ 3（要留调度开销余量） |
| 7 | 修好配置后仍报 `start-limit-hit` | 先 `systemctl reset-failed <单元>` 清计数 |
| 8 | 忘了写 `User=` | 不写默认 **root**，安全隐患 |
| 9 | `ExecStart` 用相对路径 | 必须是绝对路径 |
| 10 | 改 `/lib/systemd/system/` 下的单元 | 那是软件包的，升级会被覆盖；放 `/etc/systemd/system/` |
| 11 | 用 `kill -15` 测自动重启，结果看不出效果 | 用 `kill -9` 才算"强杀"，最严苛 |
| 12 | 看 `status` 被截断（`...`） | 加 `-l`（`systemctl status -l`）或看 `journalctl` |

---

## 八、命令详解（本项首次出现的命令与参数）

### 8.1 `systemctl` 全套

```bash
systemctl start   X      # 现在启动
systemctl stop    X      # 停止
systemctl restart X      # 重启进程
systemctl reload  X      # 让进程重读自己的配置（不改进程）
systemctl enable  X      # 设开机自启（建软链）
systemctl disable X      # 取消自启
systemctl status  X      # 状态（-l 不截断）
systemctl is-active  X   # 是否在跑（active/inactive/failed）
systemctl is-enabled X   # 是否自启（enabled/disabled）
systemctl is-failed  X   # 是否失败
systemctl mask    X      # 彻底屏蔽（连手动 start 都拒绝）
systemctl unmask  X      # 解除屏蔽
systemctl reset-failed X # 清除失败状态和重启计数
systemctl list-units --type=service --state=running
systemctl list-unit-files --state=enabled
systemctl show -p NRestarts --value X   # 查单个属性
systemctl show -p MainPID --value X
systemctl cat X          # 查看单元文件内容
systemctl edit X         # 生成覆盖片段（drop-in），不改原文件
systemctl daemon-reload  # 重读所有单元配置
```

**`show -p` 是取值的利器**：`systemctl show -p MainPID --value lab05-heartbeat` 直接输出 PID 数字，适合脚本里用。

**`systemctl edit X`** 会创建 `/etc/systemd/system/X.service.d/override.conf`，**只写要改的部分**，比直接改原文件更安全（软件包升级不会被覆盖）。

### 8.2 `systemd-analyze`

```bash
systemd-analyze verify /etc/systemd/system/xxx.service   # 语法检查
systemd-analyze blame                                    # 各单元启动耗时
systemd-analyze critical-chain                           # 关键启动链
systemd-analyze time                                     # 总启动耗时
```

**`verify` 是启动前必做的检查**，能抓出拼写错误、缺 `ExecStart` 之类的问题。

### 8.3 `journalctl` 按单元看

```bash
journalctl -u lab05-heartbeat            # 某单元日志
journalctl -u lab05-heartbeat -f         # 实时跟随
journalctl -u lab05-heartbeat -n 20      # 最后 20 行
journalctl -b -u lab05-heartbeat         # 只看本次开机
journalctl -u lab05-heartbeat -o short-unix   # 时间戳转 Unix 秒，方便相减
journalctl -u lab05-heartbeat --since "15 min ago"
journalctl -u lab05-heartbeat --since "2026-10-28 03:00" --until "2026-10-28 04:00"
journalctl _PID=2740                     # 按 PID 过滤
```

- `-u` = unit，最常用的过滤方式
- `-o short-unix` 输出秒级时间戳，**算恢复时间就用它**
- 普通用户看系统日志需要 `sudo`（或加入 `adm` / `systemd-journal` 组）

### 8.4 here-document（`<<EOF`）

```bash
sudo tee /path/file > /dev/null <<'EOF'
内容
EOF
```

| 写法 | 行为 |
|---|---|
| `<<'EOF'` | **不展开**变量、命令替换、反斜杠（推荐写脚本用） |
| `<<EOF` | 展开 `$VAR`、`$(cmd)`、`` `cmd` `` |
| `<<-EOF` | 额外允许行首 Tab 缩进 |

**用途**：一次写多行文件，不用反复 `echo >>`。

### 8.5 `timeout`

```bash
timeout 7 命令         # 7 秒后发 SIGTERM
timeout -s KILL 7 命令  # 7 秒后发 SIGKILL
timeout -k 2 7 命令     # 7 秒后 TERM，再等 2 秒还没死就 KILL
```

**测试死循环脚本的标配**，避免手工 `Ctrl+C`。

### 8.6 命令替换 `$(...)`

```bash
P=$(systemctl show -p MainPID --value lab05-heartbeat)
sudo kill -9 $P
```

`$(...)` 先执行括号里的命令，把**标准输出**替换到那个位置。比反引号 `` `...` `` 更清晰、可嵌套。

### 8.7 `ln -s`（`enable` 的底层动作）

```bash
ln -s 目标 链接名       # 建符号链接
ls -l 链接名            # 看它指向哪
```

### 8.8 `chmod +x`

```bash
chmod +x 脚本           # 给所有身份加执行权限
chmod u+x 脚本          # 只给属主
```

### 8.9 `tee` 与 `> /dev/null`

```bash
sudo tee /etc/systemd/system/x.service > /dev/null <<'EOF'
```

- `tee` 以 sudo 身份写文件（解决 `sudo echo >` 不生效的问题）
- 不加 `> /dev/null` 的话内容会同时打到屏幕，写长文件时刷屏

---

## 九、口头验收记录（2026-10-28）

| 问题 | 回答要点 | 判定 |
|---|---|---|
| 三段职责？`WantedBy` 在 enable 时具体做了什么？ | `[Unit]` 元信息+依赖；`[Service]` 怎么跑/身份/指令/失败处理；`[Install]` 在哪里启用。补充：enable 实质是在 `multi-user.target.wants/` 下建软链 | ✅ 首答漏细节，补充后完整 |
| `Type=simple` 与 `forking` 区别？前台死循环写成 `forking` 会怎样？ | simple 的进程即主进程、立刻算成功；forking 等父进程退出才算成功。写错会一直等父进程退出，直到超时报错 | ✅ |
| `always` 与 `on-failure` 区别？`RestartSec` 最大能设多少？ | always 任何退出都重启；on-failure 只非正常退出才重启。`RestartSec` 不能 ≥5，要留 systemd 调度时间，建议 ≤3 | ✅ 首答误答"关机"且说"最大 5s"，纠正后通过 |
| `enable` 与 `start` 区别？为何要 `daemon-reload`？ | enable 设自启但不启动；start 立刻启动但不自启；daemon-reload 让 systemd 重新扫描解析 unit | ✅ |
| `StartLimitBurst` 干什么？闸门落下后还要做什么？ | 防止无限重启超过阈值后停止重试；除了改配置还要清除之前的失败计数（`reset-failed`） | ✅ |

**首答时的三处错误（已纠正）：**

1. 把"进程退出"说成"关机" → `Restart=` 与机器关机无关
2. 认为 `RestartSec` 最大可设 5 → 实际必须 < 5
3. Q1/Q4 没说出"enable 建软链"这个实质动作

---

## 十、遗留 / 后续

- [ ] 06 日志分析（先拍快照 `lab-06-开始`）；本项已用到 `journalctl -u/-b/-n/-f`，06 会扩展到按时间/优先级过滤
- [ ] 没实测 `systemctl edit`（drop-in 覆盖），实际运维很常用，可补
- [ ] 没实测 `notify` 类型（`sd_notify`），做 nginx 或 Python 服务时可补
- [ ] 服务仍在跑：`sudo systemctl disable --now lab05-heartbeat` 可清理（脚本和 unit 文件留着不影响其他实验）
- [ ] 本项的 `/data` 属主已被 04 改成 `madrough:madrough`，与 03 笔记里的记录不同
