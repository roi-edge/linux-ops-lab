# 16 Docker 基础

> 实验日期：2026-11-13
> 环境：Ubuntu 24.04.5 LTS（`ubuntulearn` / `192.168.9.50`），**Docker 29.1.3**（Ubuntu `docker.io` 包），**Storage Driver: `overlayfs`**（containerd snapshotter）
> 快照：`lab-16-开始`
> 关联：[03 磁盘挂载](03-磁盘分区与挂载.md)（新盘分区挂载）、[12 数据库](12-数据库.md)（`bind-address` 的对比）、[13 备份](13-备份脚本.md)（卷数据）、[15 故障演练](15-故障演练.md)（磁盘满）

---

## 一、目标与验收

**做：** 跑 nginx 和 mysql 容器；映射端口、挂载目录、看日志、进容器

**验收：** 能说清"**容器里改了文件，为什么重启就没了**"

**结论：** 达成，而且**纠正了验收题目里的说法** ——

> **"重启"（`docker restart`）不会丢改动**（实测 `CHANGED BY LAB16` 在 restart 后依然在）。
> **真正丢改动的时刻是"容器被删除重建"**（`docker rm` / `compose up --build` / 滚动更新）—— 那时会从**没变过的镜像**建一个**空的可写层**。

**另外两个重要产出：**
1. **Docker 发布的端口绕过 `ufw`**（实测 `ufw` 里没有 8088，Windows 却能拿到 200）—— 生产头号容器安全坑。
2. **Docker 29 用 containerd snapshotter，镜像大头在 `/var/lib/containerd` 而不是 `/var/lib/docker`** —— 只挪 `data-root` 等于挪了个寂寞（根分区一度到 97%）。

---

## 二、最终状态

### 2.1 磁盘布局（本项最重要的基础设施改动）

```bash
madrough@ubuntulearn:~$ df -h / /data /var/lib/docker /var/lib/containerd | tail -4
/dev/mapper/ubuntu--vg-ubuntu--lv  9.8G  7.8G  1.5G  84% /
/dev/sdb1                          2.0G  9.8M  1.9G   1% /data
/dev/sdc1                           30G  1.4G   27G   5% /var/lib/docker
/dev/sdc1                           30G  1.4G   27G   5% /var/lib/containerd
```

**注意后两行是同一个 `sdc1`** —— `/var/lib/containerd` 是通过 **bind mount** 挂到 `/var/lib/docker/containerd` 上的。

| 挂载点 | 设备 | 来源 | fstab |
|---|---|---|---|
| `/` | `ubuntu--vg-ubuntu--lv`（LVM，10G） | 出厂 | 有 |
| `/data` | `/dev/sdb1`（2G） | 实验 03 加的盘 | `UUID=565fb750-... defaults,nofail,x-systemd.device-timeout=5s 0 2` |
| **`/var/lib/docker`** | **`/dev/sdc1`（30G）** | **本项加的盘** | `UUID=6042d36f-31f7-4914-88c4-dacabc05e6c2 /var/lib/docker ext4 defaults,nofail,x-systemd.device-timeout=5s 0 2` |
| **`/var/lib/containerd`** | （bind 到 sdc1） | **本项迁移** | `/var/lib/docker/containerd /var/lib/containerd none bind,nofail 0 0` |

**迁移前后的对比：**

| 时刻 | 根分区可用 | 说明 |
|---|---|---|
| 装 Docker 前 | 1.8G（81%） | 基线 |
| 拉了 3 个镜像后 | **371M（97%）** ⚠️ | `containerd` 吃了 1.2G 在根分区 |
| 把 containerd 也挪走后 | **1.5G（84%）** | 恢复健康 |

### 2.2 镜像

```bash
madrough@ubuntulearn:~$ sudo docker images
IMAGE                ID             DISK USAGE   CONTENT SIZE   EXTRA
hello-world:latest   cf1b20a0c89a       25.9kB         9.49kB
mysql:8              a81d043930e5       1.12GB          254MB    U
nginx:alpine         713fc2ebfd92       94.5MB         27.3MB   U
```

**Docker 29 改了输出列**：`DISK USAGE`（占磁盘，**含共享层重复计算**）vs `CONTENT SIZE`（实际内容）。老教程里只有 `SIZE` 一列。

**`mysql:8` 实际是 `8.4.13`** —— **tag 是浮动的**，`8` 现在指向 8.4 LTS。

### 2.3 容器与卷

| 名称 | 镜像 | 端口 | 挂载 | 状态 |
|---|---|---|---|---|
| `lab16-bind2` | `nginx:alpine` | **8088→80** | **bind**：`/data/docker-html` → `/usr/share/nginx/html` **(`:ro`)** | Up |
| `lab16-mysql2` | `mysql:8`（8.4.13） | **3307→3306** | **volume**：`lab16-mysql-data` → `/var/lib/mysql` | Up |
| `lab16-mysql-data` | — | — | `Mountpoint: /var/lib/docker/volumes/lab16-mysql-data/_data`（在 sdc1 上） | — |

### 2.4 镜像加速器

```json
// /etc/docker/daemon.json
{
  "registry-mirrors": ["https://docker.m.daocloud.io"]
}
```

**探测结果（5 个候选）：**

| 镜像站 | `/v2/` 返回 | 结论 |
|---|---|---|
| **docker.m.daocloud.io** | **401** | ✅ **采用**（401 = 服务正常，需认证） |
| hub.rat.dev | 302 | ⚠️ 重定向，不冒险 |
| dockerproxy.cn / docker.1panel.live / docker.rainbond.cc | 000 | ❌ 不可达 |

---

## 三、操作步骤（按真实顺序）

### 3.1 摸底

```bash
# 身份：madrough @ ubuntulearn（普通用户，sudo 提权）
madrough@ubuntulearn:~$ command -v docker && docker --version || echo "docker 未安装"
madrough@ubuntulearn:~$ df -h / /data | tail -2
madrough@ubuntulearn:~$ free -h | head -2
madrough@ubuntulearn:~$ sudo ss -tlnp | grep -E ':(80|443|3306|3307|8080|8088) ' | head -6
```

**实测：Docker 未装；`/` 1.8G 可用；内存 3.8G（可用 2.9G）；80/3306 已被本机 nginx/MySQL 占，8088/3307 空闲。**

### 3.2 加一块 30G 盘（VMware 关机操作）

| 步骤 | 操作 |
|---|---|
| ① | 关机（`poweroff`） |
| ② | 虚拟机 → 设置 → 添加 → 硬盘 → SCSI |
| ③ | **创建新虚拟磁盘** |
| ④ | 大小 **30GB**；**不勾**"立即分配"；**单个文件** |
| ⑤ | 开机 |

**为什么先加盘**：Docker 的镜像层、容器层、卷全在 `/var/lib` 下。根分区只剩 1.8G，一个 `mysql:8` 就 1.1G —— 不加盘必然重演实验 15 的"磁盘满"。

### 3.3 分区

```bash
# 身份：madrough @ ubuntulearn（普通用户，sudo 提权）
madrough@ubuntulearn:~$ sudo fdisk /dev/sdc <<'EOF'
n
p
1


w
EOF
madrough@ubuntulearn:~$ lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT /dev/sdc
```

**`n p 1 回车 回车 w`** = 新建 / 主分区 / 编号 1 / 默认起始（**1MiB 对齐**）/ 默认结束（占满）/ 写入。

### 3.4 格式化 + 持久挂载到 `/var/lib/docker`

```bash
# 身份：madrough @ ubuntulearn（普通用户，sudo 提权）
madrough@ubuntulearn:~$ sudo mkfs.ext4 -L docker /dev/sdc1
madrough@ubuntulearn:~$ sudo blkid -s UUID -o value /dev/sdc1
madrough@ubuntulearn:~$ sudo cp -a /etc/fstab /root/fstab.lab16.bak
madrough@ubuntulearn:~$ echo "UUID=$(sudo blkid -s UUID -o value /dev/sdc1) /var/lib/docker ext4 defaults,nofail,x-systemd.device-timeout=5s 0 2" | sudo tee -a /etc/fstab
madrough@ubuntulearn:~$ sudo mkdir -p /var/lib/docker
madrough@ubuntulearn:~$ sudo systemctl daemon-reload
madrough@ubuntulearn:~$ sudo mount -a
madrough@ubuntulearn:~$ df -h /var/lib/docker | tail -1
```

**实测：`/dev/sdc1 30G 24K 28G 1% /var/lib/docker`。**

**为什么挂 `/var/lib/docker` 而不是改 `data-root`**：Docker 的默认数据目录就是它，**不做任何配置就生效**；改 `data-root` 只是把同一件事写到配置里，多一个出错点。

**⚠️ `nofail` 的两面性**：盘挂不上时系统照常启动，但 **Docker 会悄悄用到根分区上的空目录** → 又回到"根分区被写满"。所以**挂完必须 `df` 确认是 30G，不是 1.8G**。

### 3.5 装 Docker

```bash
# 身份：madrough @ ubuntulearn（普通用户，sudo 提权）
madrough@ubuntulearn:~$ sudo apt update
madrough@ubuntulearn:~$ sudo apt install -y docker.io
madrough@ubuntulearn:~$ sudo systemctl enable --now docker
madrough@ubuntulearn:~$ sudo docker info 2>/dev/null | grep -E 'Docker Root Dir|Storage Driver|Server Version'
```

**选 `docker.io` 而不是 `docker-ce` 的理由**：`docker.io` 走 `cn.archive.ubuntu.com`（**已可用**），不用加 `download.docker.com` 的 APT 源（本环境对该域名可达性未验证）。核心概念完全一样。

**实测：`Server Version: 29.1.3`、`Storage Driver: overlayfs`、`Docker Root Dir: /var/lib/docker`。**

### 3.6 配镜像加速器（先探测，别盲填）

```bash
# 身份：madrough @ ubuntulearn（普通用户）
madrough@ubuntulearn:~$ for m in docker.m.daocloud.io dockerproxy.cn docker.1panel.live hub.rat.dev docker.rainbond.cc; do code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "https://$m/v2/" 2>/dev/null); echo "$m -> ${code:-000}"; done
```

**为什么不用 `docker pull` 探测**：`pull` 失败会走完整重试（几十秒）并在本地留半截层。**`curl` 打 HTTP 请求，6 秒出结论。**

```bash
# 身份：madrough @ ubuntulearn（普通用户，sudo 提权）
madrough@ubuntulearn:~$ sudo mkdir -p /etc/docker
madrough@ubuntulearn:~$ sudo tee /etc/docker/daemon.json > /dev/null <<'JSON'
{
  "registry-mirrors": ["https://docker.m.daocloud.io"]
}
JSON
madrough@ubuntulearn:~$ sudo python3 -m json.tool /etc/docker/daemon.json
madrough@ubuntulearn:~$ sudo systemctl restart docker
madrough@ubuntulearn:~$ sudo docker info 2>/dev/null | grep -A2 'Registry Mirrors'
```

**拉不动时的原始报错（留档）：**

```
Error response from daemon: failed to resolve reference "docker.io/library/hello-world:latest":
  ... dial tcp 128.242.240.29:443: connect: connection refused
```

**`python3 -m json.tool` 先校验 JSON** —— **`daemon.json` 里不允许注释**，语法错会让 dockerd 直接起不来。

### 3.7 第一个容器

```bash
# 身份：madrough @ ubuntulearn（普通用户，sudo 提权）
madrough@ubuntulearn:~$ sudo docker run --rm hello-world
madrough@ubuntulearn:~$ sudo docker images
madrough@ubuntulearn:~$ sudo docker ps -a
```

**`docker run` 做了三件事**：① 查本地镜像（没有就拉）② 用镜像创建容器（**加一层可写层**）③ 启动容器里的主进程。

`--rm` = 退出后立刻删容器 → `docker ps -a` 是空的（**这是效果的证明，不是故障**）。

### 3.8 跑 nginx 容器

```bash
# 身份：madrough @ ubuntulearn（普通用户，sudo 提权）
madrough@ubuntulearn:~$ sudo docker run -d --name lab16-nginx -p 8088:80 nginx:alpine
madrough@ubuntulearn:~$ sudo docker ps
madrough@ubuntulearn:~$ sudo docker logs --tail 5 lab16-nginx
madrough@ubuntulearn:~$ curl -s -I --max-time 3 http://127.0.0.1:8088/ | head -3
madrough@ubuntulearn:~$ sudo ss -tlnp | grep ':8088 '
```

**实测：`HTTP/1.1 200 OK`、`Server: nginx/1.31.8`；`ss` 里是 `docker-proxy`（不是 nginx 进程）。**

**`-p 8088:80` 的方向**：**前宿主机、后容器**。写反成 `-p 80:8088` 会"连得上但没响应"（容器里 nginx 听 80，而你以为它听 8088）。

### 3.9 验收核心：改的文件去哪了

```bash
# 身份：madrough @ ubuntulearn（普通用户，sudo 提权）
madrough@ubuntulearn:~$ sudo docker exec lab16-nginx sh -c 'echo "CHANGED BY LAB16" > /usr/share/nginx/html/index.html'
madrough@ubuntulearn:~$ curl -s http://127.0.0.1:8088/          # → CHANGED BY LAB16
madrough@ubuntulearn:~$ sudo docker restart lab16-nginx
madrough@ubuntulearn:~$ sleep 3
madrough@ubuntulearn:~$ curl -s http://127.0.0.1:8088/          # → CHANGED BY LAB16 ★ 还在！
madrough@ubuntulearn:~$ sudo docker rm -f lab16-nginx
madrough@ubuntulearn:~$ sudo docker run -d --name lab16-nginx2 -p 8088:80 nginx:alpine
madrough@ubuntulearn:~$ sleep 3
madrough@ubuntulearn:~$ curl -s http://127.0.0.1:8088/          # → 回到 nginx 欢迎页 ★ 没了
madrough@ubuntulearn:~$ sudo docker images | grep nginx          # → 镜像大小没变
```

**这一步的结论见第一节。**

### 3.10 正确做法：bind mount

```bash
# 身份：madrough @ ubuntulearn（普通用户，sudo 提权）
madrough@ubuntulearn:~$ mkdir -p /data/docker-html
madrough@ubuntulearn:~$ echo "SERVED FROM HOST BIND MOUNT" > /data/docker-html/index.html
madrough@ubuntulearn:~$ sudo docker rm -f lab16-nginx2
madrough@ubuntulearn:~$ sudo docker run -d --name lab16-bind -p 8088:80 -v /data/docker-html:/usr/share/nginx/html:ro nginx:alpine
madrough@ubuntulearn:~$ curl -s http://127.0.0.1:8088/          # → SERVED FROM HOST BIND MOUNT
madrough@ubuntulearn:~$ echo "CHANGED ON HOST at $(date +%T)" > /data/docker-html/index.html
madrough@ubuntulearn:~$ curl -s http://127.0.0.1:8088/          # → 立刻变了
madrough@ubuntulearn:~$ sudo docker rm -f lab16-bind
madrough@ubuntulearn:~$ sudo docker run -d --name lab16-bind2 -p 8088:80 -v /data/docker-html:/usr/share/nginx/html:ro nginx:alpine
madrough@ubuntulearn:~$ curl -s http://127.0.0.1:8088/          # → ★ 内容还在
madrough@ubuntulearn:~$ sudo docker inspect --format '{{range .Mounts}}{{.Type}} {{.Source}} -> {{.Destination}} (RW={{.RW}}){{"\n"}}{{end}}' lab16-bind2
# bind /data/docker-html -> /usr/share/nginx/html (RW=false)
```

**`:ro` 约束的是容器的挂载视图**：容器内只读，**宿主机照样能改**。

### 3.11 命名卷跑 MySQL

```bash
# 身份：madrough @ ubuntulearn（普通用户，sudo 提权）
madrough@ubuntulearn:~$ sudo docker volume create lab16-mysql-data
madrough@ubuntulearn:~$ sudo docker run -d --name lab16-mysql -p 3307:3306 \
    -e MYSQL_ROOT_PASSWORD='<MYSQL_ROOT_PASSWORD>' -e MYSQL_DATABASE=lab16db \
    -v lab16-mysql-data:/var/lib/mysql mysql:8
madrough@ubuntulearn:~$ sudo docker ps --filter name=lab16-mysql
```

**实测：`Up`，端口 `0.0.0.0:3307->3306/tcp`，另有 `33060/tcp` 只有声明（`EXPOSE`）没有发布。**

### 3.12 连进去造数据 + 看容器内配置

```bash
# 身份：madrough @ ubuntulearn（普通用户）
madrough@ubuntulearn:~$ mysql -h 127.0.0.1 -P 3307 -u root -p'<MYSQL_ROOT_PASSWORD>' -e "SELECT VERSION(); CREATE DATABASE IF NOT EXISTS persist_test; CREATE TABLE persist_test.t (id INT PRIMARY KEY, note VARCHAR(50)); INSERT INTO persist_test.t VALUES (1,'survived the rebuild'); SELECT * FROM persist_test.t;"
# → 8.4.13 ！（mysql:8 现在是 8.4 LTS）
# → survived the rebuild

madrough@ubuntulearn:~$ sudo docker exec lab16-mysql mysql -uroot -p'<MYSQL_ROOT_PASSWORD>' -e "SELECT @@bind_address, @@datadir;" 2>/dev/null
# → *      /var/lib/mysql/
```

### 3.13 删容器、用同一个卷重建

```bash
# 身份：madrough @ ubuntulearn（普通用户，sudo 提权）
madrough@ubuntulearn:~$ sudo docker rm -f lab16-mysql
madrough@ubuntulearn:~$ sudo docker run -d --name lab16-mysql2 -p 3307:3306 -e MYSQL_ROOT_PASSWORD='<MYSQL_ROOT_PASSWORD>' -v lab16-mysql-data:/var/lib/mysql mysql:8
madrough@ubuntulearn:~$ sleep 40
madrough@ubuntulearn:~$ mysql -h 127.0.0.1 -P 3307 -u root -p'<MYSQL_ROOT_PASSWORD>' -e "SELECT * FROM persist_test.t;"
# → survived the rebuild ★
madrough@ubuntulearn:~$ sudo docker volume inspect lab16-mysql-data
# → Mountpoint: /var/lib/docker/volumes/lab16-mysql-data/_data
```

### 3.14 发现根分区 97%，迁移 containerd

```bash
# 身份：madrough @ ubuntulearn（普通用户，sudo 提权）
madrough@ubuntulearn:~$ sudo docker system df
# Images 3  1.213GB
madrough@ubuntulearn:~$ df -h /var/lib/docker /
# /dev/sdc1 30G 209M 28G 1%   /var/lib/docker     ← 大盘几乎空
# /         9.8G 8.9G 371M 97%                     ← 根分区要满

madrough@ubuntulearn:~$ sudo du -x -h --max-depth=1 /var/lib | sort -h | tail -6
# 1.2G  /var/lib/containerd      ← 元凶
# 2.0G  /var/lib/snapd
madrough@ubuntulearn:~$ sudo du -sh /var/lib/containerd /var/lib/docker
# 1.2G  /var/lib/containerd
# 1.1G  /var/lib/docker
```

**根因**：Docker 29 用 **containerd snapshotter**（`Storage Driver: overlayfs`），**镜像内容存在 `/var/lib/containerd`**，而它**不受 `data-root` 控制**。

**迁移（bind mount）：**

```bash
# 身份：madrough @ ubuntulearn（普通用户，sudo 提权）
madrough@ubuntulearn:~$ sudo systemctl stop docker docker.socket containerd
madrough@ubuntulearn:~$ sudo mkdir -p /var/lib/docker/containerd
madrough@ubuntulearn:~$ sudo rsync -aHAX /var/lib/containerd/ /var/lib/docker/containerd/
madrough@ubuntulearn:~$ sudo du -sh /var/lib/containerd /var/lib/docker/containerd      # ★ 两个必须一样
madrough@ubuntulearn:~$ sudo rm -rf /var/lib/containerd
madrough@ubuntulearn:~$ sudo mkdir -p /var/lib/containerd
madrough@ubuntulearn:~$ echo "/var/lib/docker/containerd /var/lib/containerd none bind,nofail 0 0" | sudo tee -a /etc/fstab
madrough@ubuntulearn:~$ sudo systemctl daemon-reload
madrough@ubuntulearn:~$ sudo mount /var/lib/containerd
madrough@ubuntulearn:~$ df -h / /var/lib/containerd | tail -2
```

**实测：根分区回到 1.5G 可用（84%），`/var/lib/containerd` 挂到 sdc1。**

**关键细节：**
- **停三个**：`docker`、`docker.socket`（不停它会被自动拉起）、`containerd`
- **`rsync -aHAX`**：containerd 的 overlay 层里有**大量硬链接**，不用 `-H` 会成倍膨胀
- **先 `du` 对比再 `rm`** —— 这一步是"迁移"和"跑路"的分界

### 3.15 重启验证 + 发现容器不会自动起来

```bash
# 身份：madrough @ ubuntulearn（普通用户，sudo 提权）
madrough@ubuntulearn:~$ sudo systemctl start containerd docker
madrough@ubuntulearn:~$ sudo docker ps -a --format 'table {{.Names}}\t{{.Status}}'
# lab16-mysql2   Exited (0) 2 minutes ago      ← 默认 --restart no，不会自动起
madrough@ubuntulearn:~$ sudo docker start lab16-bind2 lab16-mysql2
madrough@ubuntulearn:~$ curl -s http://127.0.0.1:8088/                                  # 内容还在
madrough@ubuntulearn:~$ mysql -h 127.0.0.1 -P 3307 -u root -p'<MYSQL_ROOT_PASSWORD>' -e "SELECT * FROM persist_test.t;"   # survived the rebuild
```

### 3.16 **容器端口绕过 ufw**（本项最值钱的安全发现）

```powershell
# 身份：Windows 宿主机（PowerShell）
PS C:\> curl.exe -s -I --max-time 5 http://192.168.9.50:8088/ | Select-Object -First 2
# HTTP/1.1 200 OK            ← 我们从未给 8088 加过 ufw 规则
```

```bash
# 身份：madrough @ ubuntulearn（普通用户，sudo 提权）
madrough@ubuntulearn:~$ sudo ufw status | grep -c 8088
# 0
madrough@ubuntulearn:~$ sudo iptables -t nat -S DOCKER | head -5
# -N DOCKER
# -A DOCKER ! -i docker0 -p tcp --dport 8088 -j DNAT --to-destination 172.17.0.2:80
# -A DOCKER ! -i docker0 -p tcp --dport 3307 -j DNAT --to-destination 172.17.0.3:3306
```

**证明：`ufw` 默认 deny 的情况下，`-p` 发布的端口对局域网完全开放，`ufw` 拦不住。**

---

## 四、原理

### 4.1 镜像、容器、可写层

```
镜像（只读，多层叠加）
 ├─ layer 1: base OS
 ├─ layer 2: 装 nginx
 └─ layer 3: 拷静态文件
        │  docker run
        ▼
容器 = 镜像 + 【可写层】（读写都在这一层）
        │  docker rm
        ▼
可写层被销毁 → 改动消失（镜像一个字节没动）
```

| 操作 | 可写层 | 改动 |
|---|---|---|
| `docker stop` / `start` | 保留 | 在 |
| **`docker restart`** | **保留** | **在** ← 本项实测 |
| `docker rm` | **销毁** | **没了** |
| 重新 `docker run`（新容器） | 新建一个空的 | **没了** |

**本质：可写层属于"容器的生命周期"，不属于"数据"。要活过容器的数据，必须放在容器之外。**

### 4.2 容器不是虚拟机

| | 容器 | 虚拟机 |
|---|---|---|
| 隔离的是什么 | **进程 + 命名空间**（`pid`/`net`/`mnt`/`uts`/`ipc`/`user`）+ cgroup 限资源 | **整台硬件**（Hypervisor 虚拟 CPU/内存/磁盘） |
| 内核 | **共用宿主机内核** | 自己一套内核 |
| 启动 | 毫秒~秒 | 几十秒 |
| 磁盘 | 镜像层 + 可写层（MB 级） | 完整系统盘（GB 级） |

**共用内核带来两个直接结论**：
1. **不能跑不同内核版本**（比如容器里装个别的内核 = 没用）
2. **内核漏洞会影响所有容器** —— 这是容器安全的核心风险

### 4.3 端口发布：为什么绕过 ufw

```
外部包 → PREROUTING（nat 表）
   ├─ ufw 的过滤规则（INPUT 链，默认 DROP）
   └─ ★ Docker 的 DNAT（nat 表 DOCKER 链）：8088 → 172.17.0.2:80
        │
        └─ 被 DNAT 之后，目标变成"容器的 IP"，路由判定为【转发】而非【本地交付】
             → 走 FORWARD 链，不走 INPUT 链
             → ufw 的 INPUT DROP 规则完全够不着
```

**`-A DOCKER ! -i docker0 ...` 那个 `!` 的含义**：**只要不是从 docker 网桥进来的**（即从外面进来的），就做 DNAT。

**所以：**

| 说法 | 对错 |
|---|---|
| "我开了 ufw，容器端口是安全的" | ❌ **错**。发布的端口对全网开放 |
| "`ufw status` 里没有这个端口，所以没开放" | ❌ **错**。Docker 的规则不在 ufw 里 |

### 4.4 解决容器端口绕过 ufw 的四种办法

| 办法 | 做法 | 评价 |
|---|---|---|
| **① 只绑本地回环** | `-p 127.0.0.1:8088:80` | ✅ **最推荐**。只有本机能访问，外面必须有 nginx/vpn 转发 |
| ② 用 `ufw-docker` 工具 | 装 `ufw-docker`，在 `DOCKER-USER` 链里补规则 | ✅ 保留 host 网络访问的场景 |
| ③ 手工在 `DOCKER-USER` 链加规则 | `iptables -I DOCKER-USER -i ens33 ! -s 192.168.9.0/24 -j DROP` | ⚠️ 能行，但要自己维护持久化 |
| ④ `daemon.json` 里 `"iptables": false` | 让 Docker 不碰 iptables | ⚠️ **副作用大**：容器出网/端口映射都会出问题，还需要手工配 NAT |

**`DOCKER-USER` 链是官方留的"用户自定义"钩子** —— Docker 自己的规则会先走 `DOCKER-USER`，所以你在那里加的规则**优先级高于 Docker 的 DNAT**。

### 4.5 `bind mount` vs `volume`

| | bind mount | named volume |
|---|---|---|
| 数据位置 | 宿主机指定路径 | `/var/lib/docker/volumes/<name>/_data` |
| **空目标时会怎样** | **就是空的**（镜像里那目录的内容不进来） | **Docker 会把镜像里该目录的内容复制进空卷** ← MySQL 初始化依赖这个 |
| 谁管理 | 你（权限、备份、清理都归你） | Docker（`docker volume` 系列命令） |
| 适合 | 配置、代码、静态文件、要给宿主机直接看的 | **应用数据**（数据库、上传、缓存） |
| 迁移 | 依赖宿主机路径 | `docker volume` 可导出/导入 |
| 常见坑 | 路径写错 → **静默创建一个空目录**（用 `--mount` 会报错） | 不容易直接 `ls` 看（`Mountpoint` 是 root 权限目录） |

### 4.6 `--restart` 策略（本项实测的坑）

| 策略 | 行为 |
|---|---|
| **`no`（默认）** | 停就停了。**`docker` 服务重启 / 机器重启后不会自动起** ← 本项实测 |
| `always` | 服务重启/机器重启都自动拉起；但**手动 `docker stop` 后不会** |
| `on-failure` | 只有非 0 退出才重启（可配次数） |
| **`unless-stopped`** | 除"手动 stop 过"，其他情况都自动拉起 —— **生产最常用** |

### 4.7 `EXPOSE` ≠ 发布

`Dockerfile` 里的 `EXPOSE 33060`（或镜像自带的）只做两件事：**声明**和**供 `-P` 随机映射时参考**。**不发布就不用对外暴露** —— `docker ps` 里显示成 `33060/tcp`（没有箭头）就是这个意思。

---

## 五、生产实践（实际工作中的正确做法）

### 5.1 镜像必须钉死版本，永不裸用 `latest` / 浮动 tag

```bash
# ❌ 今天拉的是 8.4.13，明天重建可能是 8.4.14 甚至 9.x
docker run mysql:8

# ✅ 钉死到补丁版本
docker run mysql:8.4.13
# 更严谨：钉到 digest（内容哈希，比 tag 更硬）
docker run mysql@sha256:a81d043930e51745522bd5c430961cf8286f0a23f0a9a2a6e0108f7ea71b0902
```

**本项实测 `mysql:8` 实际是 8.4.13** —— 说明 tag 是**浮动**的。生产重建时版本漂移会导致"昨天好好的今天崩了"。

### 5.2 日志驱动必须设大小上限（**极易忽略的磁盘炸弹**）

Docker 默认日志驱动是 **`json-file`，且没有大小限制** —— 容器里的应用往 stdout 狂打日志，**容器日志能把宿主机磁盘写满**（实验 15 的剧本 + 本项 97% 的经历）。

```json
// /etc/docker/daemon.json
{
  "registry-mirrors": ["https://docker.m.daocloud.io"],
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "3" }
}
```

**只对新建容器生效**（已有容器要重建）。单个容器也可 `--log-opt max-size=50m`。

**查容器日志占了多大：**

```bash
docker ps -s                                    # 含 Size（可写层 + 日志）
du -sh /var/lib/docker/containers/*/*-json.log   # 直接看日志文件
```

### 5.3 容器端口默认只绑本机

```bash
# ❌ 全网开放（绕过 ufw）
-p 8088:80
# ✅ 只有本机能连，要外网必须经 nginx/vpn
-p 127.0.0.1:8088:80
```

**理由见 4.3/4.4** —— 这是把"是否暴露"的控制权从 iptables 手里收回来。

### 5.4 数据一律放卷，且要给卷做备份

```bash
# 备份一个命名卷（用一次性容器把卷打包到宿主机）
docker run --rm -v lab16-mysql-data:/data -v /data/backup:/backup alpine \
  tar czf /backup/lab16-mysql-data-$(date +%F).tar.gz -C /data .
```

**要在容器停止或用一致性方式（如 `mysqldump`）导出的前提下做**，直接 `tar` 运行中的数据库文件可能拿到不一致快照（参见实验 13 的 `--single-transaction`）。

### 5.5 容器里不要用 root 运行

```dockerfile
# Dockerfile 里
RUN useradd -r -u 10001 appuser
USER 10001
```

**容器内 root ≈ 宿主机 root 的风险**（尤其 `--privileged`、挂载了 `/var/run/docker.sock` 或宿主机目录时）。**挂载宿主机目录时，容器内的 uid 直接决定宿主机文件的属主** → 用非 root + 固定的高 uid 更安全。

### 5.6 加 healthcheck，别只看"容器在跑"

```dockerfile
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD curl -fs http://localhost/ || exit 1
```

**"容器 Up" ≠ "服务可用"** —— 应用可能内部卡死、DB 连接池耗尽，进程还活着。`docker ps` 会显示 `(healthy)` / `(unhealthy)`。

### 5.7 清理命令：`prune` 是删除操作，必须先看

```bash
docker system df                 # 先看
docker image prune               # 只删 dangling（没 tag 的）
docker image prune -a            # ★ 删所有没被容器使用的镜像
docker system prune -a --volumes # ★★ 连卷一起删（会被生产事故毁掉的那种命令）
```

**`--volumes` 会删掉所有未被使用的命名卷** —— 数据直接消失。**执行前 `docker volume ls` 看清楚。**

### 5.8 `/var/lib/docker` 和 `/var/lib/containerd` 都要管

| 版本 | 镜像内容主要在 |
|---|---|
| 老版本（`overlay2`，dockerd 自己的 graphdriver） | `/var/lib/docker` |
| **新版（containerd snapshotter，`Storage Driver: overlayfs`）** | **`/var/lib/containerd`** |

**所以"改 `data-root` 挪数据"这套老经验在新版上不完整** —— 必须同时把 `/var/lib/containerd` 也挪走（bind mount 或 containerd 的 `--root` 参数）。

### 5.9 其他

| 项 | 做法 |
|---|---|
| 时区 | 容器默认 UTC；`-e TZ=Asia/Shanghai` 或挂 `/etc/localtime` |
| 资源限制 | `--memory=512m --cpus=1` 防止单个容器吃光宿主机 |
| 只读根文件系统 | `--read-only --tmpfs /tmp` 提高安全性 |
| `docker commit` | **不要用**：可写层"烤"成镜像不可复现、无版本控制 → 用 Dockerfile（实验 17） |
| 镜像来源 | 只用官方/可信镜像；必要时扫漏洞（`trivy`）。**公共镜像可能带后门，且以 root 运行** |
| 与云安全组 | 云上还有一层安全组（实验 25），**发布端口要同时考虑安全组** |

---

## 六、踩坑清单

| # | 坑 | 说明 / 正确做法 |
|---|---|---|
| 1 | 以为改 `data-root` 就万事大吉 | 新版 Docker 用 containerd snapshotter，**`/var/lib/containerd` 才是大头**，不受 `data-root` 管 |
| 2 | 装完 Docker 才发现根分区要满 | **先加盘/移目录，再拉镜像**。本项根分区一度 97% |
| 3 | 镜像拉不动就瞎填镜像站 | **先 `curl -s -o /dev/null -w '%{http_code}' https://站点/v2/`** 探测（`401` 才是活的） |
| 4 | `daemon.json` 里写注释 | **JSON 不允许注释**，dockerd 直接起不来。改完先 `python3 -m json.tool` |
| 5 | 改 `daemon.json` 后用 `systemctl daemon-reload` | 要 **`restart docker`**。`daemon-reload` 是给 systemd unit 用的 |
| 6 | 改了 `daemon.json` 的 log-opts 却发现老容器没变 | **日志驱动/大小只对新建容器生效**，老容器要重建 |
| 7 | 以为 `docker restart` 会丢容器内的改动 | **不会**。可写层保留。丢改动的是 `docker rm` / 重建容器 |
| 8 | 以为"容器还在，数据就安全" | **一次 `compose up --build`/滚动更新就全没**。数据必须放卷 |
| 9 | `-p 8088:80` 写成 `-p 80:8088` | 方向反了 → **连得上但没响应**（容器里 nginx 听 80） |
| 10 | 以为 `ufw` 能挡住容器端口 | ❌ **Docker 用 nat 表 DNAT，绕开 ufw 的 INPUT 链**。要 `-p 127.0.0.1:...` 或用 `DOCKER-USER` 链 |
| 11 | 以为 `EXPOSE` 了就能访问 | `EXPOSE` 只声明，**必须 `-p` 发布** |
| 12 | 机器重启后容器没起来 | 默认 `--restart no`。生产用 **`unless-stopped`** |
| 13 | bind mount 路径写错 | `-v` 会**静默创建空目录**（看起来"挂上了"其实是空的）。用 `--mount` 会报错 |
| 14 | bind mount 一个**非空**目录给数据库 | MySQL 镜像会**跳过初始化**，可能启动失败或行为异常。数据库用**命名卷**或空目录 |
| 15 | 改了 `-e MYSQL_ROOT_PASSWORD` 但不生效 | 那些变量**只在数据目录为空时**生效。要重来必须删卷或换卷名 |
| 16 | 以为 `mysql:8` 就是 8.0 | **实测是 8.4.13**。tag 浮动 → 生产钉死版本或 digest |
| 17 | `docker rm` 不带 `-f` 删运行中的容器 | 会报错，要先 `stop` |
| 18 | `docker system prune -a --volumes` 随手跑 | **会删掉所有未使用的卷**（数据没了）。先 `docker system df` + `docker volume ls` |
| 19 | 用 `docker commit` 保存改动 | 反模式：不可复现、无版本控制。用 Dockerfile |
| 20 | `usermod -G docker 用户` 漏了 `-a` | **覆盖**用户原有全部附加组（可能把 `sudo` 组也覆盖掉）→ 必须 `-aG` |

---

## 七、命令详解（本项首次出现）

### 7.1 镜像与容器

| 命令 / 参数 | 是什么 → 干什么 → 为什么这里用 |
|---|---|
| `docker run [选项] 镜像` | **创建 + 启动**容器（三步：查/拉镜像、建可写层、起主进程） |
| **`-d`** | detach，后台运行 → 不加会占住终端，Ctrl+C 停容器 |
| **`--name`** | 给容器起名 → 否则是随机名字，后面操作只能靠 ID |
| **`-p 宿主:容器`** | 端口发布（DNAT）→ 前宿主机、后容器；`127.0.0.1:8088:80` 只绑本机 |
| **`-v 源:目标[:ro]`** | 挂载。源是**路径**=bind mount，是**名字**=named volume |
| **`--rm`** | 容器退出后自动删除 → 一次性任务 |
| **`-e KEY=VALUE`** | 环境变量 → 官方镜像的初始化靠它 |
| `--restart` | 重启策略：`no`/`always`/`on-failure`/`unless-stopped` |
| `--filter` | `docker ps/logs` 的服务端过滤（比 `grep` 干净） |
| `--format 'table {{...}}'` | Go 模板自定义输出列 |
| `docker exec [-it] 容器 命令` | 在**运行中的**容器里执行命令 → 不进容器也能操作；`-it` 是交互 shell |
| `docker logs --tail N 容器` | 看容器 stdout/stderr（应用的"控制台输出"） |
| `docker ps -a` | 列容器，`-a` 含已退出（**排查启动失败必用**） |
| `docker images` | 列镜像。Docker 29 起有 `DISK USAGE` / `CONTENT SIZE` 两列 |
| `docker inspect [--format] 对象` | 打印完整 JSON 元数据；`--format` 用 Go 模板取字段 → **查"数据挂在哪"看 `.Mounts`** |
| `docker rm -f 容器` | 强制删除（含运行中） |
| `docker restart 容器` | 重启主进程，**可写层保留** |
| `docker start/stop` | 启/停容器（可写层保留） |

### 7.2 卷

| 命令 | 说明 |
|---|---|
| `docker volume create NAME` | 建命名卷（数据在 `/var/lib/docker/volumes/NAME/_data`） |
| `docker volume ls` | 列卷 |
| `docker volume inspect NAME` | 看 `Mountpoint`（数据在宿主机的真实路径） |
| `docker volume rm NAME` | 删卷（**数据一起删**） |

### 7.3 系统与诊断

| 命令 | 说明 |
|---|---|
| **`docker system df`** | 类似 `df`：镜像/容器/卷/构建缓存各占多少 → **容器环境查磁盘必用**（`du` 会重复计算共享层） |
| `docker system prune` | 清理未被使用的资源（**`-a` 删所有未用镜像，`--volumes` 删卷，危险**） |
| `docker info` | 守护进程信息：`Storage Driver`、`Docker Root Dir`、`Registry Mirrors`、`Cgroup Driver` |
| `docker volume/container/image prune` | 分类清理 |

### 7.4 宿主侧配套命令（本次用到的）

| 命令 | 说明 |
|---|---|
| `fdisk` 的 `n/p/1/回车/回车/w` | 新建主分区，**默认起始是 1MiB 对齐** |
| `mkfs.ext4 -L 标签` | 格式化并设卷标 |
| `blkid -s UUID -o value 设备` | **只输出 UUID 值** → 直接塞进 fstab |
| `rsync -aHAX` | 迁移目录时**保留属性/硬链接/ACL/xattr** → containerd 层里有大量硬链接 |
| `du -x -h --max-depth=1` | 逐层找大目录，`-x` 不跨文件系统 |
| `stat -c '%y %n'` | 精确取文件 mtime（改配置不生效时对比进程启动时间） |
| `python3 -m json.tool 文件` | **JSON 语法校验** → 改 `daemon.json` 后先跑它 |
| `for m in ...; do curl ... https://$m/v2/; done` | 批量探测镜像站存活 |
| `timeout 90 docker pull` | 给命令加超时 → 防网络卡死永久挂起 |

---

## 八、验收记录

| 验收项 | 结果 |
|---|---|
| 跑 nginx 和 mysql 容器 | ✅ `nginx:alpine`（8088→80）、`mysql:8`（8.4.13，3307→3306） |
| 映射端口 | ✅ `0.0.0.0:8088->80/tcp`、`0.0.0.0:3307->3306/tcp`；`33060/tcp` 只声明未发布 |
| 挂载目录 | ✅ bind mount（`/data/docker-html` → `/usr/share/nginx/html:ro`，`inspect` 显示 `RW=false`）+ named volume（`lab16-mysql-data` → `/var/lib/mysql`） |
| 看日志 | ✅ `docker logs --tail 5` 看到 nginx 启动日志、`OS: Linux 6.8.0-147-generic` |
| 进容器 | ✅ `docker exec ... sh -c` 改文件并 `cat` 验证 |
| **说清"容器改了文件为什么重启就没了"** | ✅ **纠正了题面**：`restart` **不丢**（实测 `CHANGED BY LAB16` 仍在）；`rm` + 重建**才丢**（回到欢迎页，而镜像大小不变）。本质是"可写层随容器销毁" |
| 附加：容器端口 vs ufw | ✅ **实测绕过**：`ufw` 无 8088 规则，Windows 仍 `200 OK`；`iptables -t nat -S DOCKER` 显示 DNAT 到 `172.17.0.2:80` |
| 附加：磁盘治理 | ✅ 发现根分区 97%，定位到 `/var/lib/containerd`（1.2G，不受 `data-root` 管），bind mount 迁移到 30G 盘后回到 84% |

**面试可用的一句话总结：**

> 我用 Ubuntu 的 `docker.io` 起了 nginx（`-p 8088:80` + bind mount）和 MySQL（`-v` 命名卷），验证了"容器改文件"的生命周期：`restart` 不丢、`rm` 重建才丢，因为可写层随容器销毁而镜像不变 —— 所以数据必须放卷或绑挂载。另外我实测到一个安全坑：**Docker 用 nat 表做 DNAT，发布端口完全绕过 `ufw`**，`ufw status` 里看不到但外面能直接访问，正确做法是 `-p 127.0.0.1:...` 或在 `DOCKER-USER` 链里补规则。还踩到新版 Docker 的 containerd snapshotter 把镜像大头放在 `/var/lib/containerd`，只改 `data-root` 不够，根分区一度到 97%。

---

## 九、遗留 / 后续

- [ ] **没给容器配 `--restart unless-stopped`**（本项实测了"不会自动起"，但没改）
- [ ] **没配日志大小上限**（`log-opts max-size`）—— 这是潜在的磁盘炸弹，留给实验 18/23
- [ ] 没做**卷备份**（`tar` 导出命名卷）→ 实验 19 会做
- [ ] 没做 **`--memory`/`--cpus` 资源限制**
- [ ] 没做 **healthcheck** 与"容器 Up 但服务挂了"的对比
- [ ] 没测 **`DOCKER-USER` 链**的实际拦截（只讲了四种解法，未验证）
- [ ] `/var/lib/snapd` **2.0G** 未清理（Ubuntu 预装 snap 的旧版本），可 `snap list --all` + 删 disabled
- [ ] `mysql:8` 浮动 tag 未钉死（实验 17 写 Dockerfile 时改成钉版本）
- [ ] 未做**容器时区**设置（`-e TZ=Asia/Shanghai`）
- [ ] 未测 **`--read-only`** 根文件系统
- [ ] 未做镜像漏洞扫描（`trivy`）
