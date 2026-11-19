# 17 Dockerfile

> 实验日期：2026-11-14
> 环境：Ubuntu 24.04.5 LTS（`ubuntulearn` / `192.168.9.50`），**Docker 29.1.3（legacy builder，无 buildx）**
> 快照：`lab-17-开始`
> 关联：[16 Docker 基础](16-Docker基础.md)（层、卷、端口）、[10 DNS](10-自建DNS.md)（dnvsmasq，本项被 `ubuntu-fan` 搞挂）、[15 故障演练](15-故障演练.md)（查故障的思路）

---

## 一、目标与验收

**做：** 写一个 Dockerfile，把巡检脚本打包成镜像

**验收：** **镜像小于 200MB**；**能解释每层在干什么**

**结论：** 达成，而且做出了鲜明对比：

| 镜像 | 底座 | `DISK USAGE` | `CONTENT SIZE` | 结论 |
|---|---|---|---|---|
| `lab17-inspect:naive` | `ubuntu:24.04` | **335MB** | 97.1MB | ❌ **超 200MB，不合格** |
| **`lab17-inspect:slim`** | **`alpine:3.20`** | **14MB** | **4.1MB** | ✅ **小 24 倍** |

**本项还额外收获两个真事故：**
1. **`apt install docker.io` 顺带装了 `ubuntu-fan`**，它的 `/etc/dnsmasq.d/ubuntu-fan` 里有 `bind-interfaces`，和我们的 `bind-dynamic` 冲突 → **dnsmasq 死循环重启 407 次**（装的时候不炸，**下次重启才炸**）。
2. **Ubuntu 的 `docker.io` 不带 buildx** → 老构建器**不支持 `COPY --chmod`**。

---

## 二、最终状态

### 2.1 项目文件

```bash
madrough@ubuntulearn:~/lab17/app$ ls -l
-rw-rw-r-- 1 madrough madrough 120 Nov 14 04:13 Dockerfile
-rw-rw-r-- 1 madrough madrough 195 Nov 14 04:08 Dockerfile.naive
-rwxrwxr-x 1 madrough madrough 765 Nov 14 04:01 inspect.sh
```

### 2.2 朴素版（反例）

```dockerfile
FROM ubuntu:24.04
RUN apt-get update
RUN apt-get install -y curl procps iproute2 net-tools vim
RUN mkdir /app
COPY inspect.sh /app/inspect.sh
RUN chmod +x /app/inspect.sh
CMD ["/app/inspect.sh"]
```

**`docker history` 实测（每层的钱花在哪）：**

| 层 | 大小 | 评价 |
|---|---|---|
| `ADD ubuntu-minirootfs` | **87.7MB** | 底座太重 |
| `RUN apt-get update` | **55.3MB** | **纯浪费**：包索引进了层，后面删不掉 |
| `RUN apt-get install ...` | **95MB** | 装了 `vim`/`net-tools` 这些巡检用不到的，还带 apt 缓存 |
| `RUN mkdir /app` | 8.19kB | **为一个目录开一层** |
| `COPY inspect.sh` | 12.3kB | 必要 |
| `RUN chmod +x` | 0B | **为一个权限位开一层** |
| `CMD` | 0B | 元数据，不占层 |

### 2.3 优化版（最终）

```dockerfile
FROM alpine:3.20
RUN apk add --no-cache procps
COPY inspect.sh /usr/local/bin/inspect.sh
CMD ["inspect.sh"]
```

**`docker history` 实测：**

```
b04411ee84c1  /bin/sh -c #(nop) CMD ["inspect.sh"]        0B
c6373c65e4da  /bin/sh -c #(nop) COPY file:9e12...         20.5kB
ea88bb208435  /bin/sh -c apk add --no-cache procps        1.4MB
d9e853e87e55  CMD ["/bin/sh"]                              0B
<missing>     ADD alpine-minirootfs-3.20.10-x86_64.tar.gz 8.47MB
```

**四层，合计 ≈ 9.9MB。**

### 2.4 镜像配置

```bash
madrough@ubuntulearn:~$ sudo docker inspect --format 'Cmd={{.Config.Cmd}} Entrypoint={{.Config.Entrypoint}} User={{.Config.User}} WorkDir={{.Config.WorkingDir}}' lab17-inspect:slim
Cmd=[inspect.sh] Entrypoint=[] User= WorkDir=/
```

**`User=` 是空的 → 容器内以 root 运行。** 这是生产要改的（见第五节）。

---

## 三、操作步骤

### 3.1 写巡检脚本（实验 21 的占位版）

```bash
# 身份：madrough @ ubuntulearn（普通用户）
madrough@ubuntulearn:~$ mkdir -p ~/lab17/app
madrough@ubuntulearn:~$ cat > ~/lab17/app/inspect.sh <<'SCRIPT'
#!/bin/sh
set -u

echo "=== 巡检 $(date -u '+%Y-%m-%d %H:%M:%S') UTC ==="
echo "主机: $(hostname)"
echo
echo "--- 磁盘 ---"
df -h / 2>/dev/null | tail -n +2
[ -d /data ] && df -h /data 2>/dev/null | tail -n +2
echo
echo "--- 内存 ---"
free -m 2>/dev/null | awk '/Mem:/ {printf "total=%sMB used=%sMB avail=%sMB\n", $2,$3,$7}'
echo
echo "--- 负载 ---"
awk '{printf "load: %s %s %s\n", $1,$2,$3}' /proc/loadavg 2>/dev/null
echo
echo "--- 服务 ---"
if command -v systemctl >/dev/null 2>&1; then
  for s in nginx mysql dnsmasq ssh cron; do
    printf '  %-8s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null | head -n 1)"
  done
else
  echo "  (无 systemctl：容器内看不到宿主机的 systemd)"
fi
SCRIPT
madrough@ubuntulearn:~$ chmod +x ~/lab17/app/inspect.sh
madrough@ubuntulearn:~$ sh ~/lab17/app/inspect.sh
```

**为容器化做的三个设计：**

| 设计 | 原因 |
|---|---|
| **`#!/bin/sh` + 只用 POSIX 语法** | alpine 里**没有 bash**。用 `sh` 才能同一份脚本在 Ubuntu 和 alpine 都能跑 |
| **`command -v systemctl` 判断** | **容器里没有 systemd**，硬调会 `not found`。降级输出比报错好 |
| `df` / `free` / `awk` / `hostname` | **busybox 全都有** → 一个包都不用装 |

**`<<'SCRIPT'` 的单引号是关键**：它禁止变量展开，脚本里的 `$(date ...)`、`$1`、`%s` **原样写进文件**。不加引号会把"写文件那一刻"的时间戳固化进去 —— 非常隐蔽的 bug。

**写脚本时踩到的坑（`cmd || echo` 的重复输出）：**

```sh
# ❌ 这行会输出两行
"$(systemctl is-active "$s" 2>/dev/null || echo unknown)"
# 因为 systemctl is-active 状态非 active 时：既打印状态，又以非 0 退出
#   → 打印 activating，然后 || 分支又追加 unknown

# ✅ 只取第一行
"$(systemctl is-active "$s" 2>/dev/null | head -n 1)"
```

> **通用陷阱：`cmd || echo xxx` 的前提是"cmd 失败时不输出"。** 但 `systemctl is-active`、`grep`、`diff` 都是**既输出又返回非 0** 的。

### 3.2 事故：dnsmasq 死循环重启 407 次

**现象（巡检脚本顺手发现的）：**

```
  dnsmasq  activating      ← 不是 active
```

```bash
madrough@ubuntulearn:~$ systemctl status dnsmasq --no-pager | head -8
Active: activating (auto-restart) (Result: exit-code)
Process: ExecStart=.../exec (code=exited, status=1/FAILURE)

madrough@ubuntulearn:~$ sudo journalctl -u dnsmasq -n 20 --no-pager | grep -m2 cannot
dnsmasq: cannot set --bind-interfaces and --bind-dynamic
...
systemd[1]: dnsmasq.service: Scheduled restart job, restart counter is at 407
```

**根因追查：**

```bash
madrough@ubuntulearn:~$ sudo grep -rn 'bind-' /etc/dnsmasq.d/ /etc/dnsmasq.conf
/etc/dnsmasq.d/lab10.conf:5:bind-dynamic          ← 实验 10 我们写的
/etc/dnsmasq.d/ubuntu-fan:2:bind-interfaces       ← 它！
/etc/dnsmasq.conf:134:#bind-interfaces            ← 注释掉的，无害

madrough@ubuntulearn:~$ grep -n 'ubuntu-fan' /var/log/apt/history.log | tail -1
Install: ... ubuntu-fan:amd64 (0.12.16+24.04.1, automatic), docker.io:amd64 (29.1.3-...) ...
```

**`ubuntu-fan` 是 `apt install docker.io` 顺带装的（`automatic`）**，它的配置片段：

```
# ensure that any system dnsmasq does not bind to fan-*
bind-interfaces
except-interface=fan-*
```

**完整因果链：**

```
实验 16  apt install docker.io
   → 自动装 ubuntu-fan
   → 它往 /etc/dnsmasq.d/ 丢了个 bind-interfaces
   → 但 dnsmasq 只在【启动时】读配置，所以当时一切正常（没炸）
   → 20 小时后机器重启
   → dnsmasq 读到 bind-interfaces + bind-dynamic 冲突 → 起不来
   → Restart=on-failure 让它每 2 秒重试一次 → 407 次，无人察觉
```

**修复（一条 `mv`，可逆）：**

```bash
madrough@ubuntulearn:~$ sudo mv /etc/dnsmasq.d/ubuntu-fan /root/ubuntu-fan.disabled
madrough@ubuntulearn:~$ sudo systemctl restart dnsmasq
madrough@ubuntulearn:~$ systemctl is-active dnsmasq      # active
madrough@ubuntulearn:~$ sudo ss -ulnp | grep ':53 '      # .50:53 + 127.0.0.1:53 都在
madrough@ubuntulearn:~$ dig +short www.lab.test          # 192.168.9.50
madrough@ubuntulearn:~$ dig +short www.baidu.com         # 180.101.51.40 ...
```

**为什么 `mv` 而不是改/删**：

| 做法 | 评价 |
|---|---|
| **`mv` 到 `/root/`** | ✅ 可逆、不留隐患、dnsmasq 立刻不读它 |
| 改 `ubuntu-fan` 里的行 | ⚠️ 它是包的 conffile，`apt upgrade` 时可能被覆盖或弹冲突 |
| **在 `lab10.conf` 里去掉 `bind-dynamic`** | ❌ **禁止**：`bind-interfaces` 是"启动时绑一次"，**IP 一变就废**；`bind-dynamic` 才跟着地址走（实验 11 改 IP 时靠它自动重绑） |

**两个额外知识点：**

| 现象 | 说明 |
|---|---|
| **`activating (auto-restart)` 而不是 `failed`** | `Restart=on-failure` 让"挂了"表现为"不断重试" → `systemctl --failed` **看不到它**，监控只判断 `is-active` 会一直报"activating"却找不到根因 |
| **重启 407 次却没被 `StartLimit` 拦住** | 默认限流是"10 秒内 5 次"。但 `RestartSec=2` + 每次启动耗时 → 每轮约 2.1 秒，**10 秒窗口里只凑到 4 次，永远攒不满 5 次** → 限流器永不触发。**自愈变成了重启风暴** |

### 3.3 构建朴素版

```bash
# 身份：madrough @ ubuntulearn（普通用户，sudo 提权）
madrough@ubuntulearn:~/lab17/app$ cat > Dockerfile.naive <<'EOF'
FROM ubuntu:24.04
RUN apt-get update
RUN apt-get install -y curl procps iproute2 net-tools vim
RUN mkdir /app
COPY inspect.sh /app/inspect.sh
RUN chmod +x /app/inspect.sh
CMD ["/app/inspect.sh"]
EOF
madrough@ubuntulearn:~/lab17/app$ sudo docker build -f Dockerfile.naive -t lab17-inspect:naive .
madrough@ubuntulearn:~/lab17/app$ sudo docker images | grep lab17
# lab17-inspect:naive   335MB   97.1MB
```

### 3.4 构建优化版（踩了两个坑）

**坑 1：`--chmod` 需要 BuildKit**

```dockerfile
COPY --chmod=755 inspect.sh /usr/local/bin/inspect.sh
# → the --chmod option requires BuildKit
```

```
DEPRECATED: The legacy builder is deprecated and will be removed in a future release.
            Install the buildx component to build images with BuildKit
```

**Ubuntu 的 `docker.io` 包不带 buildx** → 老构建器不支持 `--chmod`。

**坑 2 的解法（也是更正确的做法）：根本不需要 `chmod`**

```
-rwxrwxr-x 1 madrough madrough 765 inspect.sh     ← 源文件已经是 755
```

> **`COPY` 会保留源文件的权限位。** 所以只要宿主机上脚本是可执行的，拷进镜像就是可执行的 —— **少一层，还少一个坑**。

**最终构建：**

```bash
madrough@ubuntulearn:~/lab17/app$ cat > Dockerfile <<'EOF'
FROM alpine:3.20
RUN apk add --no-cache procps
COPY inspect.sh /usr/local/bin/inspect.sh
CMD ["inspect.sh"]
EOF
madrough@ubuntulearn:~/lab17/app$ sudo docker build -t lab17-inspect:slim . 2>&1 | tail -12
# Successfully tagged lab17-inspect:slim
madrough@ubuntulearn:~/lab17/app$ sudo docker images | grep lab17
# lab17-inspect:slim   14MB   4.1MB
madrough@ubuntulearn:~/lab17/app$ sudo docker run --rm lab17-inspect:slim
madrough@ubuntulearn:~/lab17/app$ sudo docker run --rm lab17-inspect:slim > /dev/null; echo $?    # 0
```

---

## 四、原理

### 4.1 镜像 = 层叠的只读文件系统

```
镜像
 ├─ 层 N    CMD [...]          （元数据，0B）
 ├─ 层 N-1  COPY inspect.sh    （20.5kB）
 ├─ 层 N-2  RUN apk add ...    （1.4MB）
 └─ 层 1    FROM alpine        （8.47MB）
```

**每条指令一条规则：**

| 指令 | 是否产生层 | 说明 |
|---|---|---|
| `FROM` / `ADD` | ✅ | 基础层 |
| `RUN` | ✅ | **每条一个层** |
| `COPY` / `ADD` | ✅ | 拷贝内容成一个层 |
| `ENV` / `LABEL` / `WORKDIR` / `USER` / `EXPOSE` | ✅（极小） | 只改元数据，但**也是层** |
| `CMD` / `ENTRYPOINT` | ❌ | **纯元数据，0B** |

### 4.2 为什么"删了也不减重"——层是只读的

```dockerfile
RUN apt-get update                       # 层 A：+55MB 索引
RUN apt-get install -y foo && rm -rf /var/lib/apt/lists/*
```

**上面这种写法没用**：`rm` 在层 B 里记录"删除"，层 A 里的 55MB **依然存在**于镜像中。

**正确写法：安装和删除必须在同一个 `RUN` 里**

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends foo \
 && rm -rf /var/lib/apt/lists/*
```

> 这和实验 15 学的 **`rm` 不释放被进程打开的文件**是同一类认知：**"删除"在只读层上不等于"空间释放"。**

### 4.3 底座选型（体积差几十倍）

| 底座 | 大小 | libc | 包管理 | 适合 |
|---|---|---|---|---|
| **`alpine`** | **~8MB** | musl | `apk` | 静态/简单脚本、Go 二进制、追求最小 |
| `debian:slim` | ~75MB | glibc | `apt` | 需要 glibc 兼容（很多预编译二进制） |
| `ubuntu` | ~78MB | glibc | `apt` | 和开发环境一致 |
| `distroless` | ~2-20MB | glibc/musl | 无 shell | 生产最终镜像（**没有 shell，攻击面最小**） |
| `scratch` | 0 | — | — | **静态编译的二进制专用**（Go/Rust） |

**alpine 的代价**：musl libc 与 glibc 不完全兼容 → 某些预编译二进制（如 Oracle 客户端、部分 Python wheel）跑不了，需要换底座或用 `gcompat`。

### 4.4 `CMD` 的两种形式（信号处理的生死差别）

| 形式 | 写法 | 实际执行 | PID 1 是谁 |
|---|---|---|---|
| **exec 形式（推荐）** | `CMD ["inspect.sh"]` | 直接 exec | **你的脚本** → 能收到 `SIGTERM` |
| shell 形式 | `CMD inspect.sh` | `/bin/sh -c "inspect.sh"` | **sh** → 信号发给 sh，脚本收不到 |

**后果**：`docker stop` 默认发 `SIGTERM` 等 10 秒；**shell 形式下脚本收不到信号** → 等 10 秒后被 `SIGKILL` → 数据可能丢、日志可能断。

### 4.5 `ENTRYPOINT` + `CMD` 的组合

| ENTRYPOINT | CMD | 结果 |
|---|---|---|
| 空 | `["inspect.sh"]` | 直接跑 `inspect.sh`（本项） |
| `["/app/run.sh"]` | `["--verbose"]` | 跑 `/app/run.sh --verbose`（CMD 作为**默认参数**） |
| `["/app/run.sh"]` | 空 | 跑 `/app/run.sh` |

**`docker run 镜像 别的命令` 会覆盖 CMD，但不会覆盖 ENTRYPOINT**（除非 `--entrypoint`）→ 这就是为什么很多工具镜像用 ENTRYPOINT 保证"必须从入口进"。

### 4.6 容器里 `df`/`free`/`/proc` 看到的到底是谁

**实测（容器里跑巡检脚本）：**

| 项 | 容器里显示 | 真实归属 |
|---|---|---|
| `df /` | `overlay 29.4G` | **overlay 的后端文件系统**（`/var/lib/docker` 所在的 sdc1，30G）—— **既不是宿主机的 `/`（9.8G），也不是容器体积** |
| `/proc/meminfo` | `3868MB` | **宿主机的**（meminfo 不做命名空间隔离） |
| `/proc/loadavg` | `0.00 0.06 0.08` | **宿主机的**（同上） |
| `systemctl` | 不存在 | 容器没有 init/systemd |

**结论：容器化巡检脚本"半盲"** —— 磁盘看到的是后端盘、内存/负载看到的是宿主机、服务完全看不到。**要真监控宿主机，必须挂载 `/proc`、`/var/lib`、`/var/run/systemd`，或者改用探针模式（HTTP/端口探测）。**

### 4.7 构建上下文与 `.dockerignore`

```bash
docker build -t x .
```

**那个 `.` 是"构建上下文"**：Docker 客户端会把**整个当前目录**打包发给 daemon。所以：

| 问题 | 后果 |
|---|---|
| 目录里有 `.git`、`node_modules`、日志、iso | **发送慢、构建慢、还可能被 `COPY .` 打进去** |
| 解决 | 写 `.dockerignore` |

```gitignore
.git
*.log
node_modules
*.iso
```

**本项实测 `Sending build context to Docker daemon 4.608kB`** —— 因为目录里只有三个小文件。**这就是好的构建上下文该有的样子。**

---

## 五、生产实践

### 5.1 多阶段构建（生产最重要的技巧）

```dockerfile
# ── 阶段 1：构建（可以有编译器、依赖、缓存，多大都行）
FROM golang:1.22 AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -o /out/app .

# ── 阶段 2：运行（只带产物）
FROM alpine:3.20
COPY --from=build /out/app /usr/local/bin/app
CMD ["app"]
```

**最终镜像不含编译器/源码/git**，体积能小一个数量级。**Java/Python/前端项目同理**（`maven:... AS build` → `jre-slim`）。

### 5.2 只装需要的，并清理缓存

| 包管理器 | 写法 |
|---|---|
| Debian/Ubuntu | `apt-get update && apt-get install -y --no-install-recommends 包 && rm -rf /var/lib/apt/lists/*`（**一条 RUN**） |
| Alpine | `apk add --no-cache 包` |
| pip | `pip install --no-cache-dir -r requirements.txt` |
| npm | `npm ci --omit=dev` + 多阶段 |

**`--no-install-recommends` 很重要**：Ubuntu 的 `Recommends` 会顺带装一堆东西（**本项 `docker.io` 顺带装 `ubuntu-fan` 就是同一个机制的后果**）。

### 5.3 不要用 root 运行

```dockerfile
RUN addgroup -S app && adduser -S -G app app
USER app
```

**理由**：容器内 root + 挂载宿主机目录/`--privileged`/`docker.sock` → 几乎等于宿主机 root。**本项实测 `User=` 为空（root），是待改项。**

**非 root 的副作用要提前想**：容器内 uid 决定宿主机文件属主；<1024 端口需要 `CAP_NET_BIND_SERVICE` 或用高位端口。

### 5.4 钉死版本

```dockerfile
# ❌
FROM alpine:latest
RUN apk add --no-cache curl
# ✅
FROM alpine:3.20
RUN apk add --no-cache curl=8.9.1-r0
```

**`latest` + 不钉包版本 = 每次构建结果都不同** → "昨天能构建，今天挂了"。

### 5.5 让层缓存真正起作用：变化频率排序

```dockerfile
# ✅ 先装依赖（变化少），再拷代码（变化多）
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

# ❌ 反过来：改一行代码，依赖全部重装
COPY . .
RUN npm ci && npm run build
```

**`docker build` 的缓存是"某层变了，它之后的全部失效"** → 把**不常变的放前面**。

### 5.6 健康检查 + 元数据

```dockerfile
LABEL org.opencontainers.image.source="https://github.com/..." \
      org.opencontainers.image.version="1.0.0"
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget -qO- http://localhost/ || exit 1
EXPOSE 8080
```

**`HEALTHCHECK` 让"容器 Up"和"服务可用"分开**；`LABEL` 方便追溯来源与版本。

### 5.7 安全扫描与签名

| 项 | 做法 |
|---|---|
| 漏洞扫描 | `trivy image 镜像名`、`docker scout cves` |
| 镜像签名 | `cosign`（防篡改） |
| 只信来源 | 只用官方/内网 registry，**不要 `docker pull` 来路不明的镜像** |
| 最小化 | 少装包 = 少 CVE。`distroless`/`scratch` 是终极手段 |

### 5.8 CI 里的构建规范

```bash
# 打上 git sha 标签，可追溯
docker build -t registry/app:$(git rev-parse --short HEAD) .
# 同时打语义版本和 latest（latest 只是便利，部署别用它）
docker tag registry/app:abc123 registry/app:1.4.2
```

**部署必须用不可变标签（sha 或 digest），`latest` 只用于本地开发。**

---

## 六、踩坑清单

| # | 坑 | 说明 / 正确做法 |
|---|---|---|
| 1 | `RUN apt-get update` 单独一层 | 索引 55MB 进了镜像**永远删不掉**。**必须和 install+清理写在同一条 RUN** |
| 2 | 用 `rm` 清理上一层的缓存 | **层只读**，`rm` 只是加"删除标记"，空间不释放 |
| 3 | 装 `vim`/`net-tools` 这类"方便"的包 | 生产镜像里不该有。**只装运行时必需的** |
| 4 | 为一个 `mkdir` 或 `chmod` 单开一层 | 合并到相邻的 `RUN`，或用 `COPY --chmod`（需 BuildKit） |
| 5 | `COPY --chmod` 报 `requires BuildKit` | Ubuntu `docker.io` 不带 buildx。**装 `docker-buildx`**，或**依赖 `COPY` 保留源文件权限**（更简单） |
| 6 | 以为 `COPY` 会把文件变成 644 | **`COPY` 保留源文件 mode**；源文件是 755 就是 755 |
| 7 | `CMD inspect.sh`（shell 形式） | PID 1 是 `sh`，**收不到 SIGTERM** → stop 要等 10 秒被 KILL。用 **exec 形式 `CMD ["inspect.sh"]`** |
| 8 | 构建上下文里有 `.git`/`node_modules` | 发送慢、构建慢。写 **`.dockerignore`** |
| 9 | 用 `latest` 底座、不钉包版本 | 构建不可复现。**钉死版本** |
| 10 | 容器里跑巡检/监控脚本，以为能看到宿主机 | **磁盘看到的是 overlay 后端盘、内存/负载是宿主机的、服务看不到**。要挂 `/proc`、`/var/run/systemd`，或改探针模式 |
| 11 | 容器里以 root 跑 | 挂载宿主机目录时 → 宿主机文件属主变 root。**加 `USER`** |
| 12 | 把依赖装完再 `COPY .` | 改一行代码就全量重装依赖。**先 COPY 依赖清单，再 COPY 源码** |
| 13 | `apt install` 不带 `--no-install-recommends` | 顺带装一堆无关包 —— **本项 `docker.io` 顺带装 `ubuntu-fan` 直接把 dnsmasq 搞挂了** |
| 14 | 装完新软件不重启、以为没事 | **`ubuntu-fan` 的 dnsmasq 冲突在装的时候不炸，重启才炸**。装完关键组件后应主动验证相关服务 |
| 15 | `systemctl is-active` 配合 `\|\| echo` | 它**既打印状态又返回非 0** → 输出重复。用 `\| head -n 1` 或先存变量 |
| 16 | 以为 `Restart=` 一定能自愈 | 可能变成**重启风暴**，且 `StartLimit` 因窗口凑不满而**不触发**（本项 407 次） |
| 17 | `docker build` 失败后直接重跑 | 先看 `history` 和报错行。**老构建器与 BuildKit 支持的特性不同**，报错信息会明确说 |

---

## 七、命令详解（本项首次出现）

### 7.1 Dockerfile 指令

| 指令 | 是什么 → 干什么 → 为什么这里用 |
|---|---|
| `FROM 镜像:标签` | 指定**基础镜像**，必须是第一条 | alpine 8MB vs ubuntu 87MB |
| `RUN 命令` | **构建时**执行，产生新层 | 装包/建目录/改权限 |
| `COPY 源 目标` | 从**构建上下文**拷文件进镜像，**保留源文件权限** | 拷巡检脚本 |
| `COPY --from=阶段` | 从**另一个构建阶段**拷产物（多阶段构建） | 生产必用 |
| `COPY --chmod=755` | 拷贝同时设权限（**需 BuildKit**） | 老构建器不支持 |
| `ADD` | 比 `COPY` 多两个能力（解压 tar、下载 URL）→ **一般用 `COPY`** | `ADD` 的隐式解压容易出意外 |
| `CMD [...]` | 容器**默认启动命令**，可被 `docker run` 后面的参数覆盖 | 用 **exec 形式**保证信号正确 |
| `ENTRYPOINT [...]` | **固定入口**，`CMD` 成为它的默认参数，不被 `docker run` 覆盖 | 工具类镜像用 |
| `ENV K=V` | 设环境变量（**构建时也生效**） | 时区、路径 |
| `ARG K` | **构建参数**（只在构建期存在，不进运行时） | 版本号注入 |
| `WORKDIR 路径` | 设工作目录（不存在会创建） | 别用 `RUN cd`（那对后续层无效） |
| `USER 用户[:组]` | 之后所有指令和容器进程的**运行身份** | 生产必加 |
| `EXPOSE 端口` | **只声明**（供 `-P` 随机映射参考），**不等于发布** | 文档作用 |
| `HEALTHCHECK` | 定义健康检查命令 | 让 `docker ps` 显示 `(healthy)` |
| `LABEL k=v` | 元数据（来源、版本、维护者） | 便于追溯 |
| `VOLUME 路径` | 声明匿名卷 | **慎用**：会掩盖后续镜像内容的修改 |

### 7.2 构建与检查

| 命令 | 是什么 → 干什么 |
|---|---|
| `docker build -t 名字:标签 .` | 构建镜像。`.` 是**构建上下文** |
| `-f 文件名` | 指定 Dockerfile（默认找 `Dockerfile`） |
| `--no-cache` | 强制不用层缓存重建 |
| `--build-arg K=V` | 传 `ARG` 的值 |
| `--target 阶段名` | 只构建到某个阶段（多阶段构建调试用） |
| `2>&1 \| tail -20` | 构建输出很长，只取尾部看结果 |
| `docker history 镜像` | **逐层列出每条指令和它的大小** ← 本项"解释每层"的核心工具 |
| `docker inspect --format '{{.Config.Cmd}}' 镜像` | 看镜像的启动配置（Cmd/Entrypoint/User/WorkDir） |
| `docker run --rm 镜像 > /dev/null; echo $?` | 验证容器**退出码**（编排系统靠它判断成败） |

### 7.3 配套

| 命令 | 说明 |
|---|---|
| `apk add --no-cache 包` | alpine 装包，**不把索引缓存留在镜像里** |
| `apt-get install -y --no-install-recommends 包 && rm -rf /var/lib/apt/lists/*` | Debian/Ubuntu 版的"不留缓存"写法（**必须同一条 RUN**） |
| `docker-buildx` | Ubuntu 上要单独装：`apt install -y docker-buildx` → 启用 BuildKit |
| `trivy image 镜像` | 镜像漏洞扫描（未安装，属遗留） |

---

## 八、验收记录

| 验收项 | 结果 |
|---|---|
| 写 Dockerfile 把巡检脚本打包成镜像 | ✅ `lab17-inspect:slim`（alpine + 4 层），`docker run --rm` 输出正常、**退出码 0** |
| **镜像小于 200MB** | ✅ **`DISK USAGE` 14MB / `CONTENT SIZE` 4.1MB**；对照朴素版 **335MB**（超限） |
| **能解释每层在干什么** | ✅ 见第二节表格：底座 8.47MB / `apk add --no-cache procps` 1.4MB / `COPY` 20.5kB / `CMD` 0B；朴素版的浪费点也逐层列出（`apt-get update` 55.3MB、install 95MB、mkdir 8.19kB、chmod 0B） |
| 附加：多阶段构建 | ❌ 未做（脚本是 shell，没有编译阶段）→ 留给遗留 |
| 附加：非 root | ❌ 未改（`User=` 为空），已列入遗留 |

**面试可用的一句话总结：**

> 我把巡检脚本打成了镜像：朴素版（ubuntu 底座 + 分步 apt）是 335MB，优化到 alpine 底座 + `apk add --no-cache` + `COPY` 保留源文件权限后是 14MB。关键认知是**层是只读的，所以"先 update 再 install 再 rm"没用，删除和安装必须在同一条 `RUN` 里**；另外 `CMD` 要用 exec 形式（否则 PID 1 是 sh，收不到 SIGTERM），构建上下文要配 `.dockerignore`，生产要用多阶段构建把编译器和源码挡在最终镜像外、并用 `USER` 降权。

---

## 九、遗留 / 后续

- [ ] **`USER` 未设**（容器内以 root 运行）→ 实验 18/19 里改
- [ ] **未做多阶段构建**（本项脚本是 shell，没有构建阶段；实验 21 若改成 Go/Python 再补）
- [ ] **未写 `.dockerignore`**（当前目录只有 3 个小文件，暂时无影响）
- [ ] 未装 **`docker-buildx`**（所以 `--chmod`、`--mount=type=cache` 都用不了）
- [ ] 未给镜像加 **`HEALTHCHECK`** 和 `LABEL`
- [ ] 未做 **`trivy` 漏洞扫描**
- [ ] 巡检脚本是**占位版**（实验 21 会升级成带退出码语义的正式版）
- [ ] 容器里"看不到宿主机服务"的问题**未解决**（需要挂 `/proc`、`/var/run/systemd` 或改探针模式）
- [ ] **`ubuntu-fan` 已被移到 `/root/ubuntu-fan.disabled`** —— 以后 `apt upgrade` 可能重新装回并再次冲突，**需要在环境快照里长期记着**
- [ ] `lab17-inspect:naive`（335MB）留着当反例，**可 `docker rmi` 回收空间**
