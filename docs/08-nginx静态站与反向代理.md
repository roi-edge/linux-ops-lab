# 08 nginx 静态站 + 反向代理

> 实验日期：2026-11-03
> 环境：Ubuntu 24.04.5 LTS（`ubuntulearn` / `192.168.9.128`），**nginx 1.24.0 (Ubuntu)**
> 快照：`lab-08-开始`

---

## 一、目标与验收

**做：** 起一个静态页；再用 `proxy_pass` 反代到本地 `python3 -m http.server 8080`

**验收：** 改过 `server_name`，能用两个不同域名指向不同站点

**结论：** 全部达成。

| 域名 | 角色 | 结果 |
|---|---|---|
| `lab1.test` | 静态站 `/var/www/lab1` | ✅ 返回 `<h1>Site 1 - lab1.test</h1>` |
| `lab2.test` | **反向代理** → `127.0.0.1:8080` | ✅ 返回后端内容，且后端只绑 `127.0.0.1` |

**额外完成：** 制造并诊断了 **502 Bad Gateway**（连不上上游）。

---

## 二、最终配置

### 目录与文件

```
/var/www/lab1/index.html                         静态站 1
/var/www/lab2/                                   （lab2 改为反代后不再用）
/var/www/backend/index.html                      后端服务的内容
/etc/nginx/sites-available/lab1.conf             站点 1 配置
/etc/nginx/sites-available/lab2.conf             站点 2 配置（反代）
/etc/nginx/sites-enabled/lab1.conf -> ../sites-available/lab1.conf
/etc/nginx/sites-enabled/lab2.conf -> ../sites-available/lab2.conf
/etc/hosts 追加：127.0.0.1 lab1.test lab2.test
```

### `lab1.conf`（静态站）

```nginx
server {
    listen 80;
    server_name lab1.test;

    root /var/www/lab1;
    index index.html;

    access_log /var/log/nginx/lab1.access.log;
    error_log  /var/log/nginx/lab1.error.log;
}
```

### `lab2.conf`（反向代理）

```nginx
server {
    listen 80;
    server_name lab2.test;

    access_log /var/log/nginx/lab2.access.log;
    error_log  /var/log/nginx/lab2.error.log;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

---

## 三、nginx 的目录约定（必须先搞清）

| 路径 | 作用 |
|---|---|
| `/etc/nginx/nginx.conf` | 主配置，里面有 `include /etc/nginx/sites-enabled/*;` |
| `/etc/nginx/sites-available/` | **所有**站点配置（写了不等于生效） |
| `/etc/nginx/sites-enabled/` | **只有这里的生效**，通常是指向 available 的**软链** |
| `/etc/nginx/conf.d/` | 另一套约定（RHEL 系常用），Ubuntu 也可用 |
| `/var/www/html/` | 默认站点根目录 |
| `/var/log/nginx/access.log` / `error.log` | 全局日志；站点里可单独指定 |

**为什么分 available / enabled**：

```bash
sudo ln -s /etc/nginx/sites-available/lab1.conf /etc/nginx/sites-enabled/   # 启用
sudo rm /etc/nginx/sites-enabled/lab1.conf                                  # 停用
```

**不改一行配置就能开关站点。** 这是 Ubuntu/Debian 的惯例，RHEL 系没有这个区分（都放 `conf.d/`）。

**本机实测 `sites-enabled/default` 就是软链：**

```
lrwxrwxrwx 1 root root 34 Nov  3 02:40 default -> /etc/nginx/sites-available/default
```

---

## 四、虚拟主机的本质（08 的核心认知）

### 4.1 `server_name` 匹配的是 `Host` 头，不是 DNS

```bash
curl -s -H "Host: lab1.test" http://127.0.0.1/    # → Site 1
curl -s -H "Host: lab2.test" http://127.0.0.1/    # → 后端内容
```

**同一个 IP、同一个端口（80），靠请求头里的 `Host` 字段分发到不同站点。**

这意味着：

- **`server_name` 和 DNS 解析毫无关系**
- 测试虚拟主机**根本不需要真域名**，一个 `-H` 就够了
- 反过来，**DNS 解析正确但 `server_name` 配错，还是访问到错误的站点**

### 4.2 `/etc/hosts` 让域名真能用

```bash
echo "127.0.0.1 lab1.test lab2.test" | sudo tee -a /etc/hosts
getent hosts lab1.test lab2.test
```

`/etc/hosts` 优先级**高于 DNS**（由 `/etc/nsswitch.conf` 的 `hosts: files dns` 决定，`files` 在前）。

```bash
curl -s http://lab1.test/    # → Site 1
curl -s http://lab2.test/    # → 后端内容
```

### 4.3 没有匹配的 `server_name` 会怎样

```bash
curl -s -H "Host: nothing.test" http://127.0.0.1/
```

**返回默认站点的内容**（本机是 nginx 欢迎页），因为 `sites-enabled/default` 里的 `listen 80 default_server;` 接住了所有未匹配的 `Host`。

| 情况 | 谁处理 |
|---|---|
| `Host` 匹配某个 `server_name` | 那个 server 块 |
| `Host` 谁都不匹配 | **`default_server`**（标了 `default_server` 的那个，没标则第一个 server） |

**排查"访问到了错误站点"时，第一查 `server_name` 拼写，第二查 `default_server` 是哪个。**

---

## 五、核心指令详解

### 5.1 server 块基本指令

| 指令 | 作用 |
|---|---|
| `listen 80` | 监听端口。`listen 80 default_server` 设为默认站 |
| `server_name a.com b.com *.a.com` | 匹配的域名列表，支持通配和正则 |
| `root /path` | 网站根目录 |
| `index index.html index.php` | 默认首页，按顺序找 |
| `access_log` / `error_log` | 分站点日志（**排查利器**） |

### 5.2 `location` 匹配优先级

| 写法 | 优先级 | 说明 |
|---|---|---|
| `location = /x` | **最高** | 精确匹配 |
| `location ^~ /static/` | 高 | 前缀匹配后**不再查正则** |
| `location ~ \.php$` | 中 | **正则**（区分大小写），按出现顺序 |
| `location ~* \.jpg$` | 中 | 正则（不区分大小写） |
| `location /api/` | 低 | 普通前缀匹配（最长优先） |
| `location /` | **最低** | 兜底 |

### 5.3 `proxy_pass` 与四个必须透传的头

```nginx
proxy_pass http://127.0.0.1:8080;
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
```

| 头 | 不传的后果 |
|---|---|
| `Host` | 后端收到 `Host: 127.0.0.1:8080`，**不知道用户访问的是哪个域名**，多站点后端会分错 |
| `X-Real-IP` | 后端看到的所有来源都是 `127.0.0.1`，**无法做 IP 限流/日志** |
| `X-Forwarded-For` | 多级代理时丢失链路 |
| `X-Forwarded-Proto` | 后端无法判断原始是 http 还是 https，**生成绝对 URL 时会错** |

**实测证据（后端日志）：**

```
127.0.0.1 - - [03/Nov/2026 03:30:34] "HEAD / HTTP/1.0" 200 -
```

后端看到的是 `127.0.0.1`——因为 Python 的 `http.server` **不解析** `X-Real-IP`。**这恰恰证明：如果后端不主动读这些头，它永远只知道"请求来自代理"。**

### 5.4 `proxy_pass` 的路径陷阱（高级）

```nginx
proxy_pass http://127.0.0.1:8080;       # 保留原始 URI：/api/x → /api/x
proxy_pass http://127.0.0.1:8080/;      # 末尾有斜杠：/api/x → /x（去掉 location 前缀）
```

**末尾的斜杠会改变路径拼接方式**，这是反代最常见的坑之一。本实验 `location /` 配 `proxy_pass ...:8080;`（无斜杠），行为等价。

---

## 六、操作步骤（可复现）

### 6.1 安装与验证

```bash
# 身份：madrough
sudo apt update && sudo apt install -y nginx
systemctl status nginx --no-pager | head -5
curl -sI http://127.0.0.1/ | head -3
sudo ss -tlnp | grep ':80 '
```

**实测：**

```
HTTP/1.1 200 OK
Server: nginx/1.24.0 (Ubuntu)

LISTEN 0  511  0.0.0.0:80  0.0.0.0:*  users:(("nginx",pid=4450,fd=5),...)
```

**`Send-Q = 511`** 是 nginx 的 backlog（对比 07 里 Python 的 `5`）。

### 6.2 建静态站

```bash
sudo mkdir -p /var/www/lab1 /var/www/lab2
echo '<h1>Site 1 - lab1.test</h1>' | sudo tee /var/www/lab1/index.html
echo '<h1>Site 2 - lab2.test</h1>' | sudo tee /var/www/lab2/index.html

sudo tee /etc/nginx/sites-available/lab1.conf > /dev/null <<'EOF'
server {
    listen 80;
    server_name lab1.test;
    root /var/www/lab1;
    index index.html;
    access_log /var/log/nginx/lab1.access.log;
    error_log  /var/log/nginx/lab1.error.log;
}
EOF

sudo ln -s /etc/nginx/sites-available/lab1.conf /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
```

### 6.3 改成反向代理

```bash
sudo mkdir -p /var/www/backend
echo '<h1>Backend by python http.server :8080</h1>' | sudo tee /var/www/backend/index.html
sudo chown -R madrough:madrough /var/www/backend

# 关键：绑 127.0.0.1，不暴露给外部
nohup python3 -m http.server 8080 --bind 127.0.0.1 --directory /var/www/backend > /tmp/backend.log 2>&1 &
curl -s http://127.0.0.1:8080/
```

（然后写 `lab2.conf`，见第二节；`ln -s` → `nginx -t` → `reload`）

### 6.4 验证三件事

```bash
curl -s http://lab1.test/           # 静态站
curl -s http://lab2.test/           # 后端内容
curl -sI http://lab2.test/          # 响应头里 Server 是 nginx
```

**`curl -sI http://lab2.test/` 实测：**

```
HTTP/1.1 200 OK
Server: nginx/1.24.0 (Ubuntu)
```

**客户端完全看不出后面是 Python** —— 这就是反代的意义：**隐藏后端、统一入口**。

### 6.5 502 演练

```bash
pkill -f "http.server 8080"
curl -si http://lab2.test/ | head -3
```

**实测：**

```
HTTP/1.1 502 Bad Gateway
```

```bash
sudo tail -3 /var/log/nginx/lab2.error.log
```

**实测：**

```
2026/11/03 03:37:00 [error] 7557#7557: *24 connect() failed (111: Connection refused)
while connecting to upstream, client: 127.0.0.1, server: lab2.test,
request: "GET / HTTP/1.1", upstream: "http://127.0.0.1:8080/", host: "lab2.test"
```

**恢复：**

```bash
nohup python3 -m http.server 8080 --bind 127.0.0.1 --directory /var/www/backend > /tmp/backend.log 2>&1 &
curl -s http://lab2.test/
```

---

## 七、502 / 503 / 504 的区别

| 码 | 含义 | 典型原因 | 第一步查什么 |
|---|---|---|---|
| **502** Bad Gateway | 代理**连不上**后端 | 进程死了、端口错、防火墙 | `ss -tlnp \| grep 后端端口` |
| **503** Service Unavailable | 服务**明确拒绝**或过载 | 应用主动 503、连接池耗尽、健康检查全挂 | 应用日志、限流配置 |
| **504** Gateway Timeout | 连上了但**等太久** | 后端处理慢、DB 卡死、超时设太短 | 后端耗时、`proxy_read_timeout` |

**口诀：**

- **502 = 门都进不去**（连接层）
- **504 = 进去了出不来**（响应超时）
- **503 = 门开着但不让你进**（应用层）

**看到 502 去查"是不是太慢"是浪费时间；看到 504 去查"进程在不在"也是浪费时间。**

### 504 怎么造

```bash
nohup python3 -c "
import http.server, time
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        time.sleep(30)
        self.send_response(200); self.end_headers()
http.server.HTTPServer(('127.0.0.1', 8081), H).serve_forever()
" > /tmp/slow.log 2>&1 &
```

`lab2.conf` 里加 `proxy_read_timeout 5s;` → reload → 访问 → 5 秒后得 504。

---

## 八、后端监听地址的安全问题（本次实际踩到）

### 8.1 现象

后端日志里出现两种来源：

```
192.168.9.1 - - [...] "GET /favicon.ico HTTP/1.1" 404 -     ← 宿主机直连了 8080
127.0.0.1   - - [...] "HEAD / HTTP/1.0" 200 -               ← 走 nginx 反代
```

**`192.168.9.1` 是 Windows 宿主机**，它直接连到了 8080——因为 `python3 -m http.server 8080` **默认绑 `0.0.0.0`**。

### 8.2 后果

| 后端绑定 | 外部入口 |
|---|---|
| `0.0.0.0:8080`（默认） | `:80`（nginx）**和** `:8080`（直连后端，绕过反代） |
| `127.0.0.1:8080`（正确） | 只有 `:80` |

**绕过反代意味着：** 隐藏后端失效、限流/鉴权失效、访问日志缺失。

### 8.3 修复

```bash
pkill -f "http.server 8080"
nohup python3 -m http.server 8080 --bind 127.0.0.1 --directory /var/www/backend > /tmp/backend.log 2>&1 &
ss -tlnp | grep ':8080 '     # 期望 127.0.0.1:8080
```

**生产规范：所有后端服务（应用、数据库、缓存）一律绑 `127.0.0.1`，只让反向代理对外。**

---

## 九、踩坑清单

| # | 坑 | 说明 / 正确做法 |
|---|---|---|
| 1 | 改完配置直接 `reload` | **必须先 `nginx -t`**，语法错了 reload 会拒绝，`restart` 则可能起不来 |
| 2 | 配置写在 `sites-available` 却不生效 | 没有 `ln -s` 到 `sites-enabled`（或忘了 `reload`） |
| 3 | 用 `restart` 而不是 `reload` | `reload` 是平滑重载、不断现有连接；只有改 `listen` 端口等才需要 `restart` |
| 4 | 改了 `sites-enabled` 里的软链目标文件，却以为是两份 | 软链和源文件是同一个文件，改哪边都一样；但**如果 enabled 是实体文件**（手工拷的），两边就不同步了 |
| 5 | heredoc 提前打了 `EOF` | 后续内容被当命令执行，出现莫名报错；用 `cat` 看文件实际内容 |
| 6 | 后端绑 `0.0.0.0` | 后端端口直接暴露，绕过反代。**必须 `--bind 127.0.0.1`** |
| 7 | 不传 `X-Real-IP` / `Host` | 后端看到的来源全是 `127.0.0.1`，且不知道真实域名 |
| 8 | 以为 `server_name` 依赖 DNS | **它只匹配 `Host` 请求头**，`curl -H` 就能测 |
| 9 | 访问到错误站点 | 查 `server_name` 拼写 → 查 `default_server` 是谁 |
| 10 | 用浏览器判断端口通不通 | 浏览器会补全端口、走缓存、自动重试。**用 `curl -v`** |
| 11 | `proxy_pass` 末尾斜杠 | `...:8080` 与 `...:8080/` 的 URI 拼接规则不同 |
| 12 | 改完配置忘了看日志 | 每个站点配了独立 `error_log`，502/404 的原因都写在里面 |

---

## 十、命令详解（本项首次出现的命令与参数）

### 10.1 `nginx` 命令行

```bash
nginx -t                    # 测试配置语法
nginx -T                    # 测试并**打印合并后的完整配置**（排查 include 时神器）
nginx -v                    # 版本
nginx -V                    # 版本 + 编译参数
nginx -s reload             # 发信号重载（等价 systemctl reload）
nginx -s stop / quit        # 停止 / 优雅停止
```

**`nginx -T` 比 `-t` 更有用**：它把 `include` 进来的所有文件合并展开，你能看到 nginx **实际**在用的配置，排除"我改的文件到底有没有被加载"的疑问。

### 10.2 `systemctl reload` vs `restart`

| 命令 | 行为 | 适用 |
|---|---|---|
| `systemctl reload nginx` | **平滑重载**配置，worker 进程优雅替换，不断连接 | 改 `server`/`location`/`proxy_*` 等 |
| `systemctl restart nginx` | 完全停止再启动，**会断连接** | 改 `listen` 端口、升级二进制 |
| `systemctl reload-or-restart` | 支持 reload 就 reload，否则 restart | 脚本里用 |

### 10.3 `ln -s`（章节四已用）

```bash
ln -s 目标 链接名              # 建软链
ln -sf 目标 链接名             # 强制覆盖已存在的
ls -l 链接名                    # 看指向
readlink -f 链接名              # 解析出真实路径
```

### 10.4 `curl` 的 `-H` / `-si` / `-sI`

```bash
curl -s -H "Host: lab1.test" http://127.0.0.1/   # 自定义请求头
curl -si http://x/                                # 显示响应头 + 正文
curl -sI http://x/                                # 只显示响应头（HEAD）
curl -s -o /dev/null -w "%{http_code}\n" http://x/  # 只取状态码
```

**`-w "%{http_code}"` 是脚本里判断健康状态的标准写法。**

### 10.5 `/etc/hosts` 与 `getent hosts`

```bash
echo "127.0.0.1 lab1.test" | sudo tee -a /etc/hosts
getent hosts lab1.test          # 按 NSS 顺序解析（会读 hosts）
cat /etc/nsswitch.conf | grep hosts    # 看解析顺序
```

**`getent hosts` 比 `cat /etc/hosts` 好**：它走完整解析流程，能验证"最终生效的是哪条"。

### 10.6 `pkill -f` 与 `nohup`

```bash
pkill -f "http.server 8080"     # 按完整命令行匹配
nohup cmd > log 2>&1 &           # 脱离终端 + 重定向输出
```

**`2>&1` = 把标准错误也重定向到标准输出**，这样 `> log` 才能同时捕获正常输出和报错。

### 10.7 日志查看

```bash
sudo tail -f /var/log/nginx/error.log      # 实时跟踪
sudo tail -20 /var/log/nginx/access.log
sudo grep "502" /var/log/nginx/*.log
```

**按站点分日志的好处**：`lab2.error.log` 里只有反代的问题，不会被其他站点的噪音淹没。

---

## 十一、验收记录

| 项 | 结果 |
|---|---|
| 静态站可访问 | ✅ `curl -s http://lab1.test/` → `<h1>Site 1 - lab1.test</h1>` |
| 反代生效 | ✅ `curl -s http://lab2.test/` → 后端内容；响应头 `Server: nginx/1.24.0` |
| **两个域名指向两个站点** | ✅ `Host: lab1.test` 与 `Host: lab2.test` 返回不同内容（本地与 Windows 双向验证） |
| 从外部（Windows）验证 | ✅ `curl.exe -H "Host: lab1.test" http://192.168.9.128/` 正常 |
| 502 诊断 | ✅ 得到 `502 Bad Gateway`，error log 定位到 `connect() failed (111: Connection refused)` |
| 后端暴露修复 | ✅ 从 `0.0.0.0:8080` 改为 `127.0.0.1:8080`，宿主机直连失败 |

---

## 十二、遗留 / 后续

- [ ] 09 防火墙（先拍快照 `lab-09-开始`）——会用 `ufw` 只放行 22/80/443，可验证"端口开了但服务没起"与"服务起了但防火墙挡了"的区别
- [ ] 未做 504 演练（原理已讲，命令已给）
- [ ] 未测 `default_server` 显式配置（本机由 `sites-enabled/default` 承担）
- [ ] 后端 Python 服务仍在跑（`127.0.0.1:8080`），可留作 09 的测试对象
- [ ] `lab2.test` 的静态目录 `/var/www/lab2` 已不再使用，可删
- [ ] 建议补：`nginx -T` 查看合并配置、`location` 优先级实测
