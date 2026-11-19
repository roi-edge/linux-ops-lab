# 18 Docker Compose

> 实验日期：2026-11-15
> 环境：Ubuntu 24.04.5 LTS（`ubuntulearn` / `192.168.9.50`），Docker **29.1.3**，**Compose V2 2.40.3**
> 快照：`lab-18-开始`
> 关联：[16 Docker 基础](16-Docker基础.md)（容器/卷/端口/ufw 绕过）、[17 Dockerfile](17-Dockerfile.md)（被 compose 直接 `build` 的镜像）

---

## 一、目标与验收

**做：** 用 compose 一条命令起 nginx + mysql + 你自己的脚本服务

**验收：** `up` / `down` / `logs` / `ps` **都会**；**能说清 network 怎么互通**

**结论：** 达成。两个核心产出：

1. **网络互通的三条路径全打通并有日志证据**：容器间用**服务名**（`web` / `db`）经 Docker 内置 DNS 解析；宿主机经网桥网关 `172.18.0.1`；外部经 `0.0.0.0:8089` 的端口发布。
2. **把实验 16 的"端口绕过 ufw"问题彻底解决**：`ports: ["127.0.0.1:3310:3306"]` → 实测 Windows **连不上**（`False`），而 `8089` 能连（`200 OK`）。**暴露面由绑定地址决定，不由防火墙决定。**

---

## 二、最终状态

### 2.1 `~/lab18/compose.yaml`（全文）

```yaml
name: lab18
services:
  web:
    image: nginx:alpine
    restart: unless-stopped
    ports: ["8089:80"]
    volumes: ["/data/docker-html:/usr/share/nginx/html:ro"]
    logging: {driver: json-file, options: {max-size: "10m", max-file: "3"}}
  db:
    image: mysql:8
    restart: unless-stopped
    ports: ["127.0.0.1:3310:3306"]
    environment:
      MYSQL_ROOT_PASSWORD: <MYSQL_ROOT_PASSWORD>
      MYSQL_DATABASE: lab18db
    volumes: ["lab18-mysql-data:/var/lib/mysql"]
    healthcheck: {test: ["CMD","mysqladmin","ping","-uroot","-p<MYSQL_ROOT_PASSWORD>"], interval: 10s, timeout: 5s, retries: 5, start_period: 40s}
    logging: {driver: json-file, options: {max-size: "10m"}}
  inspect:
    build: ../lab17/app
    restart: "no"
    depends_on: {db: {condition: service_healthy}}
    command: ["sh","-c","echo '--- DNS ---'; getent hosts web db; echo '--- web ---'; wget -qO- http://web/ | head -3; echo '--- db ---'; nc -z -w 2 db 3306 && echo 'db:3306 OK' || echo 'db:3306 FAIL'"]
volumes:
  lab18-mysql-data:
networks:
  default:
    name: lab18net
```

**用的是 YAML 的 flow 风格**（`ports: ["8089:80"]`、`{driver: json-file, ...}`）—— 和缩进风格完全等价，但**行数少一半，手工粘贴不容易错**。

### 2.2 三个服务

| 服务 | 镜像 | 端口绑定 | 挂载 | restart | 备注 |
|---|---|---|---|---|---|
| **web** | `nginx:alpine` | **`0.0.0.0:8089`→80** | bind：`/data/docker-html` → `/usr/share/nginx/html:ro` | `unless-stopped` | 对外 |
| **db** | `mysql:8` | **`127.0.0.1:3310`→3306** | 卷：`lab18_lab18-mysql-data` → `/var/lib/mysql` | `unless-stopped` | **只本机** |
| **inspect** | 本地构建 `lab18-inspect:latest` | 无 | 无 | `"no"` | **一次性任务**，跑完 `Exited (0)` |

### 2.3 网络

```bash
madrough@ubuntulearn:~/lab18$ sudo docker network inspect lab18net --format 'subnet={{range .IPAM.Config}}{{.Subnet}} gw={{.Gateway}}{{end}}'
subnet=172.18.0.0/16 gw=172.18.0.1

madrough@ubuntulearn:~/lab18$ sudo docker network inspect lab18net --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}'
lab18-db-1 172.18.0.3/16
lab18-web-1 172.18.0.2/16
```

### 2.4 端口绑定的实测对照（本项最关键的一组数据）

```bash
madrough@ubuntulearn:~/lab18$ sudo ss -tlnp | grep -E ':(8089|3310) '
LISTEN 127.0.0.1:3310   docker-proxy      ← db：只回环
LISTEN 0.0.0.0:8089     docker-proxy      ← web：全接口
```

| 端口 | Windows 侧结果 | 结论 |
|---|---|---|
| `8089` | **`HTTP/1.1 200 OK`** | 对外可达 |
| **`3310`** | **`False`**（`TCP connect failed`） | **对外不可达** ✅ |

### 2.5 网络互通的三条路径（nginx access log 实证）

```bash
madrough@ubuntulearn:~/lab18$ sudo docker compose logs --tail 3 web
web-1 | 172.18.0.4 - - "GET / HTTP/1.1" 200 ... "Wget"        ← inspect 容器（服务名解析）
web-1 | 172.18.0.1 - - "GET / HTTP/1.1" 200 ... "curl/8.5.0"  ← 宿主机（网桥网关）
web-1 | 192.168.9.1 - - "HEAD /" 200 ... "curl/8.21.0"        ← Windows（端口发布）
```

---

## 三、操作步骤

### 3.1 摸底 + 装 Compose V2

```bash
# 身份：madrough @ ubuntulearn（普通用户；sudo 提权）
madrough@ubuntulearn:~$ sudo docker compose version            # docker: unknown command（未装）
madrough@ubuntulearn:~$ apt-cache policy docker-compose-v2 docker-compose
#   docker-compose-v2: Candidate 2.40.3   ← V2，装成 docker compose 插件
#   docker-compose:    Candidate 1.29.2   ← V1，已停止维护
madrough@ubuntulearn:~$ sudo apt install -y docker-compose-v2
madrough@ubuntulearn:~$ sudo docker compose version
Docker Compose version v2.40.3
```

**必须 V2**：V1（Python 版）不认 `profiles`、`depends_on.condition`、`deploy` 等字段，且已 EOF。

### 3.2 写 compose.yaml（分两次追加）

```bash
# 身份：madrough @ ubuntulearn（普通用户）
madrough@ubuntulearn:~$ mkdir -p ~/lab18
madrough@ubuntulearn:~$ cat > ~/lab18/compose.yaml <<'YAML'
name: lab18
services:
  web:
    ...
YAML
madrough@ubuntulearn:~$ cat >> ~/lab18/compose.yaml <<'YAML'
  db:
    ...
YAML
madrough@ubuntulearn:~$ cat >> ~/lab18/compose.yaml <<'YAML'
  inspect:
    ...
volumes:
  lab18-mysql-data:
networks:
  default:
    name: lab18net
YAML
```

**为什么分三次**：一条命令粘贴 40 行，在终端里很容易被截断（本项目反复踩过）。**`>` 建文件、`>>` 追加**，每次 10 行以内。

### 3.3 校验（不启动任何东西）

```bash
madrough@ubuntulearn:~/lab18$ sudo docker compose config
```

**它会打印"解析 + 填默认值"后的最终配置**（相当于 `nginx -t` / `netplan get all`）。实测几个解析结果值得对照：

| 输出 | 说明 |
|---|---|
| `build.context: /home/madrough/lab17/app` | 相对路径被展开成绝对路径 |
| `db` 的 `host_ip: 127.0.0.1`，`web` 无 `host_ip` | 只有 db 绑回环 |
| `volumes.name: lab18_lab18-mysql-data` | **卷名被加项目名前缀** |
| `networks.default.name: lab18net` | 自定义名生效 |
| `depends_on.db: {condition: service_healthy, required: true}` | V2 自动补 `required` |

### 3.4 `up -d`

```bash
madrough@ubuntulearn:~/lab18$ sudo docker compose up -d
# WARN  Docker Compose is configured to build using Bake, but buildx isn't installed
# ✔ inspect Built / Network lab18net Created / Volume lab18_lab18-mysql-data Created
# ✔ Container lab18-db-1 Healthy (16.6s)
# ✔ Container lab18-web-1 Started (1.0s)
# ✔ Container lab18-inspect-1 Started (16.7s)
```

**`up -d` 一次做五件事：** 解析 → 构建/拉取 → 建网络 → 建卷 → **按 `depends_on` 顺序**起容器。

**注意 `db` 是 `Healthy (16.6s)` 而 `inspect` 在它之后 `Started (16.7s)`** —— 这就是 `condition: service_healthy` 在等。

### 3.5 验证网络互通

```bash
madrough@ubuntulearn:~/lab18$ sudo docker compose logs inspect
--- DNS ---
172.18.0.2        web  web
172.18.0.3        db  db
--- web ---
CHANGED ON HOST at 06:33:43
--- db ---
db:3306 OK
```

| 段 | 证明了什么 |
|---|---|
| **DNS** | **服务名能解析成 IP** ← Docker 内置 DNS（**`127.0.0.11`**） |
| **web** | 用 `http://web/` 直接访问 → 同一网络内**服务名 + 容器端口** |
| **db** | `nc -z db 3306` 通 → **容器间直连，完全没走 `-p` 端口发布** |

### 3.6 生命周期演练

```bash
madrough@ubuntulearn:~/lab18$ sudo docker compose down
# ✔ Container lab18-web-1 Removed / lab18-inspect-1 Removed / lab18-db-1 Removed
# ✔ Network lab18net Removed

madrough@ubuntulearn:~/lab18$ sudo docker compose ps -a          # 空（容器全删了）
madrough@ubuntulearn:~/lab18$ sudo docker volume ls | grep lab18
local     lab18_lab18-mysql-data                                 # ★ 卷还在

madrough@ubuntulearn:~/lab18$ sudo docker compose up -d
# ✔ Container lab18-db-1 Healthy (6.7s)    ← 比第一次 16.6s 快（卷里已初始化）
```

---

## 四、原理

### 4.1 Compose 是什么

**它是"容器的批量编排 + 声明式配置"**：把 `docker run` 的一堆参数（端口、卷、环境变量、网络、重启策略）写进一个 YAML，然后用"项目"为单位统一管理。

| 概念 | 说明 |
|---|---|
| **项目（project）** | 由 `name:` 或目录名决定 → **容器名、网络名、卷名都加前缀**（`lab18-` / `lab18net` / `lab18_lab18-mysql-data`） |
| **服务（service）** | 一类容器的"模板"（可以 `--scale web=3` 起 3 个容器） |
| **容器（container）** | 服务 + 序号 → `lab18-web-1` |
| **幂等** | `up -d` 重复跑不会重复创建；**配置变了才重建对应容器** |

### 4.2 网络怎么互通（本项验收的核心）

**Compose 自动创建一张 bridge 网络**（默认名 `<项目>_default`，本项改成 `lab18net`），并给每个容器分配 IP：

```
宿主机 192.168.9.50
  └─ docker0 / br-xxxx（网桥）172.18.0.1     ← 网关
       ├─ lab18-web-1  172.18.0.2
       ├─ lab18-db-1   172.18.0.3
       └─ lab18-inspect-1 172.18.0.4
```

**三条访问路径：**

| 从哪到哪 | 怎么走 | 实测证据（nginx access log） |
|---|---|---|
| **容器 → 容器** | **服务名** → Docker 内置 DNS（`127.0.0.11`）→ 容器 IP | `172.18.0.4` 访问 `/` |
| **宿主机 → 容器** | 网桥网关 `172.18.0.1`（宿主机在网桥上有一个 IP） | `172.18.0.1` 访问 `/` |
| **外部 → 容器** | 宿主机 `0.0.0.0:8089` → **DNAT** → `172.18.0.2:80` | `192.168.9.1` 访问 `/` |

**为什么服务名能当主机名用：**

| 机制 | 说明 |
|---|---|
| Docker 在每个容器的 `/etc/resolv.conf` 里写 **`nameserver 127.0.0.11`** | 这是 **Docker 内置 DNS**，不是宿主机的 DNS |
| DNS 里注册了网络上所有容器的**服务名 + 容器名 + 别名** | 所以 `web`、`lab18-web-1` 都能解析 |
| **服务名只在同一张网络里有效** | 宿主机 `/etc/hosts` 里**没有** `web` —— 你在宿主机 `ping web` 会失败 |

**验证方法（可以自己试）：**

```bash
docker run --rm --network lab18net alpine nslookup web     # 能解析
docker run --rm alpine nslookup web                        # 解析不了（不在那张网）
```

### 4.3 `depends_on` 的三种语义（最容易搞错）

| 写法 | 语义 | 问题 |
|---|---|---|
| 无 `depends_on` | 同时启动，不保证顺序 | 应用连不上 db 就崩 |
| `depends_on: [db]` | **只保证"db 容器启动了"** | ⚠️ 容器启动 ≠ mysql ready → 应用照样连不上 |
| **`depends_on: {db: {condition: service_healthy}}`** | **等 db 的健康检查通过** | ✅ 需要 db 配 `healthcheck` |

**实测**：第一次 `up` 时 db `Healthy` 用了 **16.6 秒**（MySQL 初始化），inspect 在 **16.7 秒**才 `Started` —— **它等了 16 秒**。如果用普通 `depends_on`，它会在一秒内启动然后连接失败。

**`service_started` / `service_healthy` / `service_completed_successfully`** 三种条件：最后一个用于"等前置任务跑完再起下一个"（比如迁移容器）。

### 4.4 `ports` 的三种写法（决定暴露面）

| 写法 | 绑定 | 外部可达 |
|---|---|---|
| `"8089:80"` | `0.0.0.0:8089` | ✅ **能**（且绕过 ufw） |
| **`"127.0.0.1:3310:3306"`** | `127.0.0.1:3310` | ❌ **不能** ← 数据库该这样 |
| 不写 `ports` | 不发布 | ❌ 只能同网络容器访问（**内部服务最佳选择**） |

**`inspect` 服务就没写 `ports`** —— 它只需要访问别人，不需要被访问。

### 4.5 `down` / `stop` / `down -v` 到底删什么

| 对象 | `stop` | **`down`** | `down -v` |
|---|---|---|---|
| 容器 | 停（保留） | **删除** | 删除 |
| 网络 | 保留 | **删除** | 删除 |
| **卷（数据）** | 保留 | **保留** ✅ | **删除** ❌ |
| 镜像 | 保留 | 保留 | 保留 |

**实测**：`down` 后 `compose ps -a` 为空，但 `docker volume ls` 里 `lab18_lab18-mysql-data` **还在**。

### 4.6 `docker compose ps` vs `docker ps`

| | 范围 | 默认含已退出？ |
|---|---|---|
| `docker ps` | **所有**容器 | ❌ |
| **`docker compose ps`** | **只当前项目** | ❌（要 `-a`） |
| `docker compose ps -a` | 当前项目全部 | ✅ |

**实测坑点**：`inspect` 跑完退出后，`compose ps` 里**看不见它** —— 一开始容易以为"服务没起来"。

---

## 五、生产实践

### 5.1 一个服务一个 compose 文件，但分环境用 override

```
compose.yaml                  # 基础（所有环境共用）
compose.override.yaml         # 本地开发（自动加载，可加端口/挂载源码）
compose.prod.yaml             # 生产（-f 显式指定）
```

```bash
docker compose -f compose.yaml -f compose.prod.yaml up -d
```

**`compose.override.yaml` 会被自动加载**（不需要 `-f`）→ 本地开发加 `volumes: 源码挂载` + 改端口很方便，**生产环境不会带上这些**。

### 5.2 变量与密钥：别把密码写进 YAML

```yaml
environment:
  MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASSWORD:?必须设置}
```

```bash
# .env（不提交到 git）
DB_ROOT_PASSWORD=xxxxxx
```

| 手段 | 用途 |
|---|---|
| `.env` + `${VAR}` | 简单变量（**注意 `.env` 要进 `.gitignore`**） |
| **`secrets:`** | Docker Swarm/Compose 的密钥机制（以文件形式挂进容器，不进环境变量、不进 `docker inspect`） |
| 外部密钥管理 | Vault / KMS / 云厂商 Secrets Manager（生产首选） |

**本项把密码明文写在 YAML 里是教学简化，生产禁止。**

### 5.3 `healthcheck` 是 `depends_on` 的前提

```yaml
healthcheck:
  test: ["CMD", "mysqladmin", "ping", "-uroot", "-p$PASS"]
  interval: 10s
  timeout: 5s
  retries: 5
  start_period: 40s      # ← 启动宽限期，这期间失败不计入 retries
```

| 参数 | 作用 |
|---|---|
| `interval` | 多久查一次 |
| `timeout` | 单次超时 |
| `retries` | 连续失败几次算 unhealthy |
| **`start_period`** | **启动宽限期**（MySQL 初始化要 30 秒，没有它会误判为 unhealthy） |

**健康检查要查"业务可用"，不是"进程在"**：`mysqladmin ping` 比 `pgrep mysqld` 靠谱。

### 5.4 资源限制

```yaml
deploy:
  resources:
    limits: {cpus: "0.5", memory: 512M}
    reservations: {memory: 256M}
```

**`deploy` 段在 `docker compose up` 下也生效**（V2 支持），不只是 Swarm。**没有限制时，一个内存泄漏的容器能把宿主机吃光。**

### 5.5 日志：默认没有上限（实验 16 的坑）

```yaml
logging:
  driver: json-file
  options: {max-size: "10m", max-file: "3"}
```

**compose 里可以按服务配，比 `daemon.json` 全局配更灵活**（全局配只影响新建容器）。

### 5.6 `restart` 与 `depends_on` 的配合

- `restart: unless-stopped` → 崩溃/重启后自动拉起
- 但**重启风暴**的风险仍在（实验 17 的 `ubuntu-fan` 事故）
- **加 `healthcheck` 才能发现"容器 Up 但服务不可用"**

### 5.7 `.dockerignore` 与构建上下文

`build: ../lab17/app` 会把**该目录整个**作为构建上下文发过去。**目录里有大文件就慢**（实验 17 已讲）。

### 5.8 Compose 与 K8s 的关系（面试常问）

| | Compose | Kubernetes |
|---|---|---|
| 定位 | **单机**多容器编排 | **集群**编排 |
| 规模 | 一台机器 | 成百上千节点 |
| 高可用 | ❌ 无 | ✅ 多副本、自动调度 |
| 学习曲线 | 低 | 高 |
| 适合 | 开发环境、小项目、单机部署 | 生产集群 |

**Compose 的定位是"开发和单机"** —— 很多公司生产用小规模单机也用 compose（配 `restart` + `healthcheck` 够用），但**要横向扩展就必须上 K8s**。

---

## 六、踩坑清单

| # | 坑 | 说明 / 正确做法 |
|---|---|---|
| 1 | YAML 用 **Tab** 缩进 | **必须是空格**。报错是 `could not find expected ':'`，很难看出是 Tab |
| 2 | 一条命令粘贴几十行 YAML | 终端容易截断。**用 `>` 建 + `>>` 分次追加**，每次 10 行内 |
| 3 | `ports: [8089:80]`（不加引号） | 会被当成 **sexagesimal（60 进制）数字**解析成怪值。**必须 `"8089:80"`** |
| 4 | `restart: no` 不加引号 | YAML 把裸 `no` 解析成布尔 `false` → 报类型错误。**写 `"no"`** |
| 5 | 卷没在顶级 `volumes:` 声明 | `refers to undefined volume`。**bind mount 不用声明，命名卷必须声明** |
| 6 | 以为 `depends_on: [db]` 就等 db 能用 | **只保证"启动了"**。要 `condition: service_healthy` + db 配 `healthcheck` |
| 7 | `healthcheck` 不写 `start_period` | MySQL 初始化 30 秒，会被误判成 unhealthy → `depends_on` 永远等不到 |
| 8 | `compose ps` 看不到某个服务 | **默认不显示已退出**的。用 `ps -a`（本项 inspect 就跑完退出） |
| 9 | 以为 `down` 会删数据 | **`down` 保留卷**；**`down -v` 才删卷** ← 生产事故级命令 |
| 10 | 宿主机 `ping web` 失败，以为 DNS 坏了 | **服务名只在 Docker 网络里有效**，宿主机 `/etc/hosts` 没有它 |
| 11 | 容器间访问写成 `localhost:3306` | ❌ 那是**自己**。**必须用服务名 `db:3306`** |
| 12 | 用 `container_name` 硬编码名字 | 和"一个服务多副本（`--scale`）"冲突（名字会撞）。**优先用服务名** |
| 13 | 密码明文写在 YAML | 用 `.env` / `secrets`，且 `.env` 进 `.gitignore` |
| 14 | `up -d` 后不改配置就想重建 | 配置变了才重建；要强制用 `--force-recreate` 或 `--build` |
| 15 | 用 `Bake` 构建但没装 buildx | 本项出现 `WARN ... buildx isn't installed`（能回退成功，但新特性用不了）。**`apt install docker-buildx`** |
| 16 | 把 `ports` 都写成 `"8088:80"` 给数据库 | 数据库只该 `"127.0.0.1:端口:端口"` 或不发布（实验 16 的 ufw 绕过问题） |
| 17 | 以为 compose 能横向扩展/高可用 | 它是**单机**编排。多副本/自动调度是 K8s 的事 |

---

## 七、命令详解（本项首次出现）

### 7.1 Compose 顶层命令

| 命令 | 是什么 → 干什么 |
|---|---|
| `docker compose up` | 建网络/卷 + 构建/拉取 + 起容器（**幂等**） |
| `-d` | 后台运行 |
| `--build` | 强制重建镜像 |
| `--force-recreate` | 强制重建容器（即使配置没变） |
| `--scale 服务=N` | 起 N 个副本（**和服务名 DNS 轮询配合**） |
| **`docker compose down`** | 停并**删除容器+网络**（**保留卷**） |
| `-v` | **连卷一起删**（⚠️ 数据丢失） |
| `--rmi all` | 连镜像一起删 |
| `--remove-orphans` | 清理不在当前文件里的容器 |
| `docker compose stop` / `start` / `restart` | 停/启/重启（**不删容器**） |
| **`docker compose ps`** | 列**本项目**容器（`-a` 含已退出） |
| **`docker compose logs`** | 汇总所有服务日志（`-f` 跟踪 / `--tail N` / `服务名` / `--since`） |
| **`docker compose config`** | **解析并打印最终配置，不启动**（相当于 `nginx -t`） |
| `docker compose build` | 只构建镜像 |
| `docker compose pull` | 只拉镜像 |
| `docker compose exec 服务 命令` | 在运行中的服务容器里执行 |
| `docker compose run --rm 服务 命令` | **新起一个一次性容器**执行（不经过端口） |
| `docker compose top` | 看服务里的进程 |

### 7.2 YAML 结构（本项出现的字段）

| 字段 | 作用 |
|---|---|
| `name:` | 项目名（决定容器/网络/卷前缀） |
| `services:` | 服务定义（核心） |
| `image:` / `build:` | 用现成镜像 / 从 Dockerfile 构建（`build: 路径` 或 `{context, dockerfile, args}`） |
| `ports:` | 端口发布，`["宿主IP:宿主端口:容器端口"]` |
| `volumes:` | 挂载（`源:目标:模式`；源是路径=bind，是名字=volume） |
| `environment:` | 环境变量（列表或映射） |
| `depends_on:` | 依赖（**带 `condition` 才等健康**） |
| `restart:` | 重启策略 |
| `healthcheck:` | 健康检查（`test`/`interval`/`timeout`/`retries`/`start_period`） |
| `logging:` | 日志驱动与大小 |
| `command:` / `entrypoint:` | 覆盖镜像的 CMD / ENTRYPOINT |
| `networks:` | 接入的网络（默认全接 `default`） |
| 顶级 `volumes:` / `networks:` | **声明**（命名卷必须声明；网络可选） |
| `deploy.resources.limits` | CPU/内存限制 |

### 7.3 调试用的 docker 原生命令

| 命令 | 用途 |
|---|---|
| `docker network ls` / `inspect` | 看网络列表 / 子网、网关、接入的容器 |
| `docker network inspect --format '{{range .Containers}}...'` | Go 模板提取容器 IP |
| `docker volume ls` / `inspect` | 卷列表 / 挂载点 |
| `ss -tlnp \| grep :端口` | **验证 `0.0.0.0` 还是 `127.0.0.1`** |
| `Test-NetConnection -Port` | Windows 侧验证外部可达性 |

---

## 八、验收记录

| 验收项 | 结果 |
|---|---|
| 一条命令起 nginx + mysql + 脚本服务 | ✅ `docker compose up -d` 起 3 个服务；`inspect` 由实验 17 的 Dockerfile **自动构建**（`lab18-inspect:latest`） |
| **`up` 会用** | ✅ `up -d` 建网络/卷 + 按 `depends_on` 顺序启动；**幂等**（第二次复用卷，db 6.7s 就 healthy） |
| **`down` 会用** | ✅ `down` 删 3 容器 + 网络，**保留卷**（`docker volume ls` 验证）；**明确知道 `-v` 会删数据** |
| **`logs` 会用** | ✅ `logs --tail 3 web` 看到三个来源的访问日志；`logs inspect` 看到探测输出 |
| **`ps` 会用** | ✅ `compose ps`（只本项目）/ `ps -a`（含已退出的 `inspect`） |
| **能说清 network 怎么互通** | ✅ 三条路径 + 实测证据：容器间走**服务名 → 内置 DNS `127.0.0.11`**（`172.18.0.4`）；宿主机走网桥网关（`172.18.0.1`）；外部走端口发布（`192.168.9.1`） |
| 附加：解决 ufw 绕过问题 | ✅ `127.0.0.1:3310:3306` → Windows **`False`**；`8089` → **`200 OK`** |

**面试可用的一句话总结：**

> 我用 Compose 一个文件起了 nginx + MySQL + 一个自建的巡检容器：三者自动进同一张 bridge 网络（`172.18.0.0/16`），**互访靠服务名**——Docker 在每个容器里塞了 `127.0.0.11` 这个内置 DNS，服务名只在网络内有效。MySQL 我配了 `healthcheck` 加 `depends_on: condition: service_healthy`，所以巡检容器是真的等到数据库能响应才启动的，而不是"容器起来了就起"。端口暴露我用 `127.0.0.1:3310:3306` 把数据库钉死在本机——这解决了我之前发现的"Docker 发布端口绕过 ufw"的问题，暴露面由绑定地址决定而不是防火墙。生命周期上 `down` 只删容器和网络、**保留卷**，`down -v` 才会删数据，这是必须清楚的区别。

---

## 九、遗留 / 后续

- [ ] **密码明文写在 compose 里**（`<MYSQL_ROOT_PASSWORD>`）→ 生产该用 `.env` / `secrets`
- [ ] 未做 **`compose.override.yaml` 多环境**拆分
- [ ] 未做 **`--scale web=3`** 多副本 + 服务名 DNS 轮询验证
- [ ] 未做 **`deploy.resources.limits`** 资源限制
- [ ] 未装 **`docker-buildx`**（`up` 时出现 `Bake ... buildx isn't installed` 警告）
- [ ] `inspect` 服务**只探测了端口/TCP**，没真正连 MySQL 执行 SQL（实验 19 会做数据卷与备份）
- [ ] 未做 **`profiles`**（按需启用服务）
- [ ] 未做 **容器日志大小上限的实测**（配置写了 `max-size: 10m`，但没验证轮转）
- [ ] **实验 16 的两个容器 `lab16-bind2` / `lab16-mysql2` 还在**（`Exited`），占着 8088/3307 的映射声明，可 `docker rm` 清掉
- [ ] 未做 **compose 与 systemd 的结合**（`Restart=always` 的 compose 服务，开机自启另一种做法）
