# Linux 运维实验环境（可复现）

> 21 个实验 / 1 台 Ubuntu 24.04 / 全程命令行
> **目标：换一台新 VM，照本文 1 小时内复现**
> 最后验证：2026-11-19，Ubuntu 24.04.5 LTS，`192.168.9.50`

---

## 0. 这是什么

一台 VMware 里的 Ubuntu，从裸系统开始，按 `docs/01` ~ `docs/21` 的顺序做了 21 个实验：

用户/权限 → 磁盘 → systemd → 日志 → 网络 → nginx → 防火墙 → 自建 DNS → 静态 IP →
MySQL → 备份 → rsync → 故障演练 → Docker → Dockerfile → Compose → 数据卷 → Ansible → 巡检脚本。

本仓库 = **可执行的配置**（`configs/` + `scripts/`）+ **每一步的推理过程**（`docs/`）。
`docs/` 里每篇都有固定的八节：目标 / 成果 / 步骤 / 原理 / 踩坑 / 命令详解 / 验收 / 遗留。

## 1. 复现后应验证到的状态

| # | 组件 | 验证命令 | 期望 |
|---|---|---|---|
| 1 | SSH | `ssh madrough@192.168.9.50` | 能登录，`whoami` = madrough |
| 2 | 静态 IP | `ip -4 a show ens33` | `192.168.9.50/24` |
| 3 | DNS | `dig +short www.lab.local @127.0.0.1` | `192.168.9.50` |
| 4 | nginx 静态 | `curl -s -H 'Host: lab1.test' http://127.0.0.1/` | 返回自定义 HTML |
| 5 | nginx 反代 | `curl -s -H 'Host: lab2.test' http://127.0.0.1/` | 返回后端 8080 的内容 |
| 6 | 防火墙 | `sudo ufw status` | `active`，22/80/443/53/3306 放行 |
| 7 | MySQL | `mysql -h 192.168.9.50 -u lab -p -e 'SELECT 1'` | 输出 1 |
| 8 | 备份 | `ls -l /data/backup/mysql/ \| tail -1` | 有当天的 `.sql.gz` |
| 9 | rsync | `ls /data/rsync-dst` | 与 `/data/rsync-src` 一致 |
| 10 | Docker | `sudo docker ps` | 有容器在跑 |
| 11 | Compose | `curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8089` | `200` |
| 12 | 巡检脚本 | `/usr/local/bin/lab21-healthcheck.sh >/dev/null; echo $?` | `0`/`1`/`2` |

## 2. 环境要求

| 项 | 值 | 说明 |
|---|---|---|
| 虚拟化 | VMware Workstation，**NAT**（VMnet8 = `192.168.9.0/24`） | 网关 `.2`，DHCP 池 `.128`–`.254` |
| 系统 | Ubuntu 24.04.x LTS | 实测 24.04.5；24.04.3 镜像同样可用 |
| 规格 | 2 vCPU / 4 GB / 系统盘 20 G | 实测 `/` 用到 8.3 G |
| 数据盘 | 20 G 挂 `/data`；30 G 给 `/var/lib/docker` | 见 4.8 |
| 用户 | `madrough`，在 `sudo` 组 | 密码自定 |
| 时区 | UTC | 看日志时间要 +8 |

> ⚠️ **本文所有 `192.168.9.50` 要换成你实际的 IP**：
> `grep -rl 192.168.9.50 configs docs | xargs sed -i 's/192.168.9.50/你的IP/g'`

### 2.1 前置：一块数据盘

**在 VMware 里给这台 VM 再加一块 20G 虚拟盘**（第 4.0 步要用）。关机状态加，或热添加后 `lsblk` 确认能看到（如 `sdb`）。

> 仓库**不在这里克隆**：第 4.1 步建好 `madrough` 之后，用 `madrough` 身份 clone 到 `~/lab22`。
> 原因：第 4 节之后的所有命令都以 madrough 身份、在 `~/lab22` 里执行；先 clone 成别的用户，切过去就没这个目录了。

## 3. 仓库结构

```
.
├── README.md            # 本文：复现指南
├── docs/                # 21 篇实验笔记（含命令详解）
├── scripts/             # 5 个可执行脚本
└── configs/             # 从 /etc 和项目目录收集的配置原文
```

`configs/` 里的文件名**保持 `/etc` 下的原名**，对照表：

| 文件 | 原始位置 | 用途 |
|---|---|---|
| `lab1.conf` / `lab2.conf` | `/etc/nginx/sites-available/` | 静态站 / 反向代理 |
| `lab10.conf` | `/etc/dnsmasq.d/` | 本地域 + 上游 DNS |
| `90-lab11.yaml` | `/etc/netplan/` | 静态 IP |
| `lab13-mysql-backup` | `/etc/cron.d/` | 每天 02:30 宿主机 mysqldump |
| `lab19-docker-backup` | `/etc/cron.d/` | 每天 03:30 容器 mysqldump |
| `dnsmasq`（logrotate） | `/etc/logrotate.d/` | 日志轮转 |
| `lab05-heartbeat.service` | `/etc/systemd/system/` | 自愈演示服务 |
| `restart.conf` | `/etc/systemd/system/dnsmasq.service.d/` | dnsmasq 自愈 drop-in |
| `mysqld.cnf` | `/etc/mysql/mysql.conf.d/` | bind-address + skip_name_resolve |
| `daemon.json` | `/etc/docker/` | 镜像加速器 |
| `compose-lab18.yaml` | `~/lab18/` | 3 服务编排 |
| `Dockerfile-lab17` / `-naive` | `~/lab17/app/` | 14 MB 成品 / 335 MB 反例 |
| `inventory` / `ansible.cfg` / `site.yaml` / `bad.yaml` | `~/lab20/` | 幂等 playbook |

## 4. 复现步骤（按顺序，标 ★ 的是硬门槛）

### 4.0 数据盘挂到 `/data`（约 5 分钟，先做）
> 前提：VM 里已有第二块 20G 盘（见 2.1）。没有就先关机加盘。

```bash
lsblk                                   # 确认新盘，例如 sdb（20G）
sudo mkfs.ext4 /dev/sdb1                 # 已分区则直接格式化；没分区先 fdisk
sudo mkdir -p /data
echo "UUID=$(sudo blkid -s UUID -o value /dev/sdb1) /data ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
sudo systemctl daemon-reload && sudo mount -a
```
**验证**：`df -h /data` 有 20G；`findmnt /data`。
> **`nofail` 不能省**：写错或盘掉了，没有它系统会卡在 `local-fs.target` 进 emergency（`docs/03`、`docs/15`）。

### 4.1 系统与 SSH（约 5 分钟）
```bash
sudo apt update && sudo apt install -y openssh-server
sudo systemctl enable --now ssh
sudo useradd -m -s /bin/bash madrough && sudo passwd madrough
sudo usermod -aG sudo madrough
sudo systemctl set-default multi-user.target
```
**验证**：从宿主机 `ssh madrough@<IP>`，再 `whoami; sudo -v`。
> ⚠️ **之后所有步骤都用 `madrough` 身份**：`su - madrough`（要输 madrough 密码）或直接 SSH 登录。
> `usermod -aG sudo` 是**下次登录才生效**的，刚加完不重新登录，`sudo` 可能还不认。

建好用户、切过去之后，**在 madrough 名下克隆仓库**：

```bash
su - madrough
sudo apt install -y git
git clone https://github.com/roi-edge/linux-ops-lab.git ~/lab22
cd ~/lab22
```

> 从这一步起，**第 4 节的所有命令都在 `~/lab22` 里、以 madrough 身份执行**。换个终端先 `cd ~/lab22`。

### 4.2 静态 IP（约 5 分钟）
```bash
sudo cp configs/90-lab11.yaml /etc/netplan/
sudo netplan try          # 在 VMware 控制台里执行，SSH 里改必断
```
**验证**：`ip -4 a show ens33` 是 `192.168.9.50/24`；`ip route` 有 `default via 192.168.9.2`。
> 详细坑（cloud-init 覆盖、`try` 回滚不删文件）见 `docs/11-静态IP.md`。

### 4.3 自建 DNS（约 10 分钟）
```bash
sudo apt install -y dnsmasq
sudo cp configs/lab10.conf /etc/dnsmasq.d/
sudo systemctl restart dnsmasq && systemctl is-active dnsmasq
```
**验证**：`dig +short www.lab.local @127.0.0.1` → `192.168.9.50`。

关键点：netplan 里 DNS 只写 `127.0.0.1` **一个入口**，上游冗余放进 dnsmasq 的 `server=`。
> 为什么不能写两个入口：`docs/11` 的"开机竞速"。

### 4.4 nginx 两站点（约 10 分钟）
```bash
sudo apt install -y nginx
sudo mkdir -p /var/www/lab1 && echo '<h1>lab1</h1>' | sudo tee /var/www/lab1/index.html
sudo cp configs/lab1.conf configs/lab2.conf /etc/nginx/sites-available/
sudo ln -s /etc/nginx/sites-available/lab1.conf /etc/nginx/sites-enabled/
sudo ln -s /etc/nginx/sites-available/lab2.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
python3 -m http.server 8080 --bind 127.0.0.1 --directory /var/www/lab1 &
```
**验证**：`curl -s -H 'Host: lab1.test' http://127.0.0.1/` 与 `-H 'Host: lab2.test'` 返回不同内容。
> `server_name` 匹配的是 `Host` 头，不是 DNS；后端必须 `--bind 127.0.0.1`（`docs/08`）。

### 4.5 防火墙（约 5 分钟）★
```bash
sudo ufw allow 22/tcp
sudo ufw allow 80,443/tcp
sudo ufw allow 53
sudo ufw allow from 192.168.9.0/24 to any port 3306
sudo ufw default deny incoming && sudo ufw --force enable
```
**验证**：`sudo ufw status verbose`；从宿主机 `nc -zv 192.168.9.50 22` 通、未放行端口不通。
> ⚠️ **Docker 的 `-p` 会绕过 ufw**，见第 5 节。

### 4.6 MySQL（约 10 分钟）★
```bash
sudo apt install -y mysql-server
sudo cp configs/mysqld.cnf /etc/mysql/mysql.conf.d/
sudo systemctl restart mysql
sudo mysql -e "CREATE DATABASE labdb CHARACTER SET utf8mb4;"
sudo mysql -e "CREATE USER 'lab'@'192.168.9.%' IDENTIFIED BY '<DB_PASSWORD>';"
sudo mysql -e "GRANT SELECT,INSERT,UPDATE,DELETE ON labdb.* TO 'lab'@'192.168.9.%';"
```
**验证**：`mysql -h 192.168.9.50 -u lab -p -e 'SELECT 1'` 通；`mysql -h 127.0.0.1 -u lab -p` 失败（绑的是具体地址）。
> 三层门：`bind-address` / `ufw` / `user@host`，判据见 `docs/12`。

### 4.7 备份 + rsync（约 10 分钟）
```bash
sudo mkdir -p /data/backup/mysql
sudo install -m 755 scripts/mysql-backup.sh /usr/local/bin/
sudo install -m 644 configs/lab13-mysql-backup /etc/cron.d/
sudo mysql -e "CREATE USER 'bkp'@'localhost' IDENTIFIED BY '<BACKUP_PASSWORD>'; GRANT SELECT,LOCK TABLES,SHOW VIEW,EVENT,TRIGGER ON labdb.* TO 'bkp'@'localhost';"
printf '[client]\nuser=bkp\npassword=<BACKUP_PASSWORD>\n' | sudo tee /etc/mysql/backup.cnf >/dev/null
sudo chmod 600 /etc/mysql/backup.cnf
```
**验证**：`sudo /usr/local/bin/mysql-backup.sh` 后 `ls -l /data/backup/mysql/`；`zcat 最新.sql.gz | tail -1` 看到 `Dump completed`。
> 密码替换 + 三重校验 + `find -mtime +6`，见 `docs/13`；rsync 见 `docs/14`（`-aHA`、`--delete` 前先 `-n`）。

### 4.8 Docker + 数据盘（约 10 分钟，**最费时，可跳过**）
```bash
sudo apt install -y docker.io docker-compose-v2
sudo mkdir -p /var/lib/docker /var/lib/containerd
echo "UUID=$(sudo blkid -s UUID -o value /dev/sdc1) /var/lib/docker ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
sudo mount -a && sudo mkdir -p /var/lib/docker/containerd
echo '/var/lib/docker/containerd /var/lib/containerd none bind,nofail 0 0' | sudo tee -a /etc/fstab
sudo mount /var/lib/containerd
sudo cp configs/daemon.json /etc/docker/ && sudo systemctl restart docker
```
**验证**：`sudo docker info | grep -E 'Docker Root Dir|Storage Driver'`；`df -h /var/lib/docker`。
> ⚠️ **只挪 `/var/lib/docker` 不够**：新版 containerd snapshotter 的主体在 `/var/lib/containerd`，
> 要额外 bind mount，否则根分区会被吃满（`docs/16`）。`/dev/sdc1` 按你的实际盘名改。

### 4.9 Compose（约 5 分钟，**依赖 4.8 的 Docker；没做 4.8 就跳过**）
```bash
mkdir -p ~/lab18 ~/lab17/app /data/docker-html
cp configs/compose-lab18.yaml ~/lab18/compose.yaml
cp configs/Dockerfile-lab17 ~/lab17/app/Dockerfile
cp scripts/inspect.sh ~/lab17/app/
echo '<h1>lab18</h1>' | sudo tee /data/docker-html/index.html
cd ~/lab18 && sudo docker compose up -d
```
**验证**：`curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8089` → `200`；`sudo docker compose ps -a`。
> 三个前置：`web` 挂的 `/data/docker-html` 必须**先有 index.html**（空目录 403 不是 200）；
> `inspect` 服务是 `build: ../lab17/app`，所以 `~/lab17/app` 必须存在；`compose ps` 不显示已退出的容器，要 `-a`。
> `depends_on: condition: service_healthy` 才真的等数据库就绪（`docs/18`）。

### 4.10 Ansible（约 5 分钟）
```bash
ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519      # 已有则跳过
ssh-copy-id madrough@192.168.9.50                     # 免密登录
sudo apt install -y ansible-core                       # ⚠️ 约 600 MB，先看磁盘
mkdir -p ~/lab20 && cp configs/{inventory,ansible.cfg,site.yaml,bad.yaml} ~/lab20/
cd ~/lab20 && ansible-playbook site.yaml -K
```
**验证**：第二遍 `changed=0`（幂等）。
> 三个前提：**SSH 免密**（`ssh-copy-id`）、**`ansible.cfg` 在当前目录**、**`become: true` 需要 sudo 密码**
> → 所以必须带 `-K`（`--ask-become-pass`，交互输入 sudo 密码）。没配免密 sudo 却忘了 `-K`，会报
> `Missing sudo password`。`ansible.cfg` 的查找优先级见 `docs/20`。

### 4.11 巡检脚本（约 5 分钟）★
```bash
sudo install -m 755 scripts/lab21-healthcheck.sh /usr/local/bin/
/usr/local/bin/lab21-healthcheck.sh; echo "退出码=$?"
```
**验证**：退出码 `0`（OK）/ `1`（WARN）/ `2`（CRIT）；用 `DW=95 DC=100` 覆盖阈值可复现三档。
> 脚本不能用 `set -e`；浮点比较用 `awk`（`docs/21`）。

## 5. 已知坑（都是实测，不是听说）

| # | 坑 | 怎么办 |
|---|---|---|
| 1 | **DNS 必须单入口** | netplan 里只写 `127.0.0.1`。写两个时，resolved 比 dnsmasq 早启动 5 秒会把自建 DNS 降级且**不自动切回**，表现为"重启后本地域名全挂" |
| 2 | **改 IP 必须走 VMware 控制台** | `netplan try` 的确认回车按在运行它的终端里；SSH 一断就按不到 → 超时回滚。且 `try` 回滚**不删文件**，磁盘上还是错配置 |
| 3 | **`.local` 被 resolved 判给 mDNS** | 实验域名用 `.test`；要用 `.local` 得靠 netplan 的 `search:`（不带 `~` 既是搜索域也是路由域） |
| 4 | **`docker -p` 绕过 ufw** | nat 表 DNAT 走 FORWARD，不进 INPUT。要控暴露面就 `-p 127.0.0.1:...` 或改 `DOCKER-USER` 链 |
| 5 | **根分区只剩 1 GB** | `ansible-core` 一个人吃 600 MB。装任何东西前 `apt install --dry-run` 估体积；应急 `journalctl --vacuum-size=100M`、`apt clean` |
| 6 | **containerd 不在 `data-root` 里** | 迁 Docker 数据必须同时处理 `/var/lib/containerd`（bind mount） |
| 7 | **`ubuntu-fan` 会毒死 dnsmasq** | 它写 `bind-interfaces`，与 `bind-dynamic` 冲突 → dnsmasq 起不来、重启几百次。`apt upgrade` 后检查 `/etc/dnsmasq.d/` |
| 8 | **上游把 TTL 压到 5 秒** | 本环境做不了缓存命中率类实验；判断缓存要看 TTL，且两次 `dig` 要放进同一个 shell 行 |
| 9 | **`snap remove --revision` 不省空间** | snapd 会把镜像搬进 `/var/lib/snapd/cache` 保回滚，删了也会被填回 |
| 10 | **`mysqldump` 报 Error 但退出码 0** | 判成功要三层：退出码 + stderr 无 Error + 产物里有 `Dump completed` |

## 6. 密码与脱敏

仓库里**没有**任何真实密码，统一是占位符：

| 占位符 | 用在哪 |
|---|---|
| `<USER_PASSWORD>` | 系统用户 / sudo |
| `<LAB_PASSWORD>` | 实验 02 的测试账号 |
| `<DB_PASSWORD>` | MySQL `lab` 账号 |
| `<BACKUP_PASSWORD>` | 备份专用账号（`/etc/mysql/backup.cnf`） |
| `<MYSQL_ROOT_PASSWORD>` | 容器 MySQL root |

用法：把占位符换成你自己的密码，**并且不要提交回去**。
入仓前自检：

```bash
git grep -nE '554556|Lab@2026|LabDb@2026|Bkp@2026|Root@2026' || echo "干净"
```

`/etc/mysql/backup.cnf` 是本机**真凭证**，从未进入本仓库；`.gitignore` 里也挡了 `backup.cnf`、`*.key`、`*.pem`、`.env`。

## 7. 实验索引

| # | 实验 | 一句话结论 |
|---|---|---|
| 01 | [环境基线](docs/01-环境基线.md) | SSH + 普通用户 + 关图形界面 |
| 02 | [用户与组/权限/ACL](docs/02-用户与组-权限-ACL.md) | SGID 共享目录 + ACL + mask |
| 03 | [磁盘分区与挂载](docs/03-磁盘分区与挂载.md) | fstab 写错会进 emergency |
| 04 | [进程与资源排查](docs/04-进程与资源排查.md) | load 是队列长度，不是占用率 |
| 05 | [systemd 服务](docs/05-systemd服务.md) | `enable` 只建软链，`kill -9` 3 秒自愈 |
| 06 | [日志分析](docs/06-日志分析.md) | 按时间/单元/标识/优先级四维过滤 |
| 07 | [网络命令](docs/07-网络命令.md) | `ss` 四要素定位端口占用 |
| 08 | [nginx 静态站与反代](docs/08-nginx静态站与反向代理.md) | `server_name` 匹配 Host 头 |
| 09 | [防火墙](docs/09-防火墙.md) | 防火墙挡 vs 服务没起：超时 vs 立即拒绝 |
| 10 | [自建 DNS](docs/10-自建DNS.md) | `no-resolv` + `bind-dynamic` |
| 11 | [静态 IP](docs/11-静态IP.md) | netplan 后加载覆盖先加载；开机竞速 |
| 12 | [数据库](docs/12-数据库.md) | bind / ufw / user@host 三层门 |
| 13 | [备份脚本](docs/13-备份脚本.md) | 退出码 0 不等于备份成功 |
| 14 | [rsync 同步](docs/14-rsync同步.md) | `-a` 不含硬链接和 ACL |
| 15 | [故障演练](docs/15-故障演练.md) | 5 类故障，每个 30 分钟内修好 |
| 16 | [Docker 基础](docs/16-Docker基础.md) | `restart` 不丢改动，`rm` 重建才丢 |
| 17 | [Dockerfile](docs/17-Dockerfile.md) | 335 MB → 14 MB，逐层解释 |
| 18 | [Docker Compose](docs/18-DockerCompose.md) | 健康依赖、端口收敛、网络互通 |
| 19 | [数据卷与备份](docs/19-数据卷与备份.md) | 逻辑 3.1 K vs 物理 6.3 M |
| 20 | [Ansible](docs/20-Ansible.md) | 第二遍 `changed=0` 才叫幂等 |
| 21 | [巡检脚本](docs/21-巡检脚本.md) | 退出码 0/1/2 给监控用 |

## 8. 复现自检

```bash
# 一条命令跑完第 1 节的所有检查
for c in "dig +short www.lab.local @127.0.0.1" "curl -s -o /dev/null -w %{http_code} -H 'Host: lab2.test' http://127.0.0.1/" "systemctl is-active nginx mysql dnsmasq ufw"; do echo "--- $c"; eval "$c"; done
```

全部符合第 1 节的期望 = 复现成功。

---

> 配置样本来自一台真实跑过 21 个实验的机器，**密码已脱敏、凭证文件未入仓**。
> 笔记里的报错、时间戳、退出码都是实测输出，不是示例。
