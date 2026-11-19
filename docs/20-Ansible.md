# 20 Ansible 入门

> 实验日期：2026-11-17
> 环境：Ubuntu 24.04.5 LTS（`ubuntulearn` / `192.168.9.50`），**ansible-core 2.16.3**
> 快照：`lab-20-开始`
> 关联：[14 rsync](14-rsync同步.md)（SSH 免密的遗留，本项补上）、[19 数据卷与备份](19-数据卷与备份.md)（`env -i` 与"演练模式"的同类思路）

---

## 一、目标与验收

**做：** 用 ansible 给本机装 nginx、建用户；**同一份 playbook 跑两遍**

**验收：** **第二遍显示 `changed=0`（幂等）**

**结论：** 达成。

```
第一遍:  ok=6  changed=3     （user / 目录 / 文件 三个资源被创建）
第二遍:  ok=6  changed=0     ← 验收标准
```

**最有价值的认知**：**幂等来自"用模块"，不来自"写 playbook"。**

```
apt 模块 第一遍 ok（nginx 实验 08 就装过）、第二遍 ok
shell: apt-get install -y nginx   → 两遍都 changed=1（永远不收敛）
```

---

## 二、最终状态

### 2.1 工作目录 `~/lab20/`

```
inventory     # 主机清单
ansible.cfg   # 配置（inventory 路径）
site.yaml     # 正式 playbook（5 个任务，全用模块）
bad.yaml      # 反例（用 shell，永不幂等）
```

### 2.2 `inventory`

```ini
[lab]
ubuntulearn ansible_host=192.168.9.50 ansible_user=madrough
```

### 2.3 `ansible.cfg`

```ini
[defaults]
inventory = ./inventory
```

### 2.4 `site.yaml`

```yaml
- name: lab20 基础配置
  hosts: lab
  become: true
  tasks:
    - name: 确保 nginx 已安装
      apt: {name: nginx, state: present}

    - name: 确保 nginx 运行且开机自启
      service: {name: nginx, state: started, enabled: true}

    - name: 建运维用户 opsuser
      user: {name: opsuser, shell: /bin/bash, create_home: true}

    - name: 建站点目录
      file: {path: /srv/lab20, state: directory, mode: "0755"}

    - name: 部署首页
      copy: {content: "lab20 DEPLOYED BY ANSIBLE v2\n", dest: /srv/lab20/index.html, mode: "0644"}
```

### 2.5 配套改动

| 项 | 内容 |
|---|---|
| **SSH 密钥** | `~/.ssh/id_ed25519`（ed25519，**空密码短语**）+ 已 `ssh-copy-id` 到本机 |
| **免密 sudo** | `/etc/sudoers.d/90-lab20-nopasswd`，内容 `madrough ALL=(ALL) NOPASSWD:ALL`，**权限 440**，`visudo -c` 通过 |
| 已创建的资源 | 用户 `opsuser`、目录 `/srv/lab20`（0755）、文件 `/srv/lab20/index.html`（0644） |

---

## 三、操作步骤

### 3.1 摸底

```bash
# 身份：madrough @ ubuntulearn（普通用户；sudo 提权）
madrough@ubuntulearn:~$ apt-cache policy ansible-core ansible | grep -E 'ansible|Candidate'
#   ansible-core: 2.16.3-0ubuntu2       ← 小（~40MB）
#   ansible:      9.2.0+dfsg-0ubuntu5   ← 全量（300MB+）
madrough@ubuntulearn:~$ systemctl is-active nginx; dpkg -l nginx | tail -1
#   active / ii nginx 1.24.0-2ubuntu7.19      ← ⚠️ nginx 早就装好了
madrough@ubuntulearn:~$ ls -l ~/.ssh/id_* 2>&1 | head -3
#   No such file or directory                  ← 没有 SSH 密钥
```

**关键前提**：**nginx 在实验 08 就装好了** → 这会直接影响演示（第一遍就是 `ok` 而不是 `changed`）。

### 3.2 装 ansible-core（不装全量）

```bash
madrough@ubuntulearn:~$ sudo apt install -y ansible-core
madrough@ubuntulearn:~$ ansible --version | head -1
ansible [core 2.16.3]
```

**装完根分区从 1.2G 掉到 566M（95%）** —— 见 3.3。

### 3.3 磁盘告急 → 清理

```bash
madrough@ubuntulearn:~$ du -sh /var/cache/apt/archives; sudo journalctl --disk-usage
#   60K  /var/cache/apt/archives        ← 没什么可清
#   Archived and active journals take up 476.8M
madrough@ubuntulearn:~$ sudo apt clean
madrough@ubuntulearn:~$ sudo journalctl --vacuum-size=100M
madrough@ubuntulearn:~$ df -h / | tail -1
#   9.8G  8.2G  1.1G  89% /              ← 回收约 370M
```

**这个插曲本身是个教训**：**装个工具包就能把根分区从 88% 推到 95%**。容器环境（实验 16-19）把数据挪到大盘后，**根分区仍是薄弱环节**。

### 3.4 配 SSH 免密（Ansible 的前提）

```bash
madrough@ubuntulearn:~$ ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
madrough@ubuntulearn:~$ ssh-copy-id -i ~/.ssh/id_ed25519.pub madrough@192.168.9.50
madrough@ubuntulearn:~$ ssh -o BatchMode=yes madrough@192.168.9.50 true && echo "免密 OK"
# 免密 OK
```

| 参数 | 为什么 |
|---|---|
| `-t ed25519` | 比 RSA 更短更安全 |
| **`-N ''`** | **空密码短语** —— 自动化必须（否则每次都要输） |
| **`ssh -o BatchMode=yes … true`** | **禁止交互**：需要密码就立刻失败，骗不了人 |

### 3.5 配免密 sudo（`become` 的前提）

```bash
madrough@ubuntulearn:~$ echo 'madrough ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-lab20-nopasswd
madrough@ubuntulearn:~$ sudo chmod 440 /etc/sudoers.d/90-lab20-nopasswd
madrough@ubuntulearn:~$ sudo visudo -c
#   /etc/sudoers: parsed OK
#   /etc/sudoers.d/90-lab20-nopasswd: parsed OK
madrough@ubuntulearn:~$ sudo -n true && echo "免密 sudo OK"
```

**三条规矩（缺一个都可能把自己搞成没有 sudo）：**

| 规矩 | 原因 |
|---|---|
| 写进 `/etc/sudoers.d/` 的**独立文件** | 别动 `/etc/sudoers` 本体，坏了容易单独删掉 |
| **`chmod 440`** | sudo 会**忽略权限过宽的文件**（组/其他可写 = 谁都能给自己加 sudo） |
| **`visudo -c` 校验** | **语法错会让所有 sudo 失效**（实验 03 的 emergency 同款风险） |

**`sudo -n true`** 的 `-n` = 非交互：需要密码就失败。

### 3.6 inventory + cfg + 连通性测试

```bash
madrough@ubuntulearn:~$ mkdir -p ~/lab20 && cd ~/lab20
madrough@ubuntulearn:~/lab20$ cat > inventory <<'INV'
[lab]
ubuntulearn ansible_host=192.168.9.50 ansible_user=madrough
INV
madrough@ubuntulearn:~/lab20$ cat > ansible.cfg <<'CFG'
[defaults]
inventory = ./inventory
CFG
madrough@ubuntulearn:~/lab20$ ansible -m ping all
# ubuntulearn | SUCCESS => {
#     "ansible_facts": {"discovered_interpreter_python": "/usr/bin/python3"},
#     "changed": false, "ping": "pong" }
```

**`ansible -m ping` 不是 ICMP 的 ping**：它是"SSH 登录 → 跑 Python → 返回 pong"，**一次验证三件事**（SSH 免密、目标有 Python、模块能落地）。

### 3.7 写 playbook + 两次运行

```bash
madrough@ubuntulearn:~/lab20$ ansible-playbook --syntax-check site.yaml    # 无输出 = 通过
madrough@ubuntulearn:~/lab20$ ansible-playbook --list-tasks site.yaml      # 列出 5 个任务
madrough@ubuntulearn:~/lab20$ ansible-playbook site.yaml
# PLAY RECAP: ok=6  changed=3
madrough@ubuntulearn:~/lab20$ ansible-playbook site.yaml
# PLAY RECAP: ok=6  changed=0        ★ 验收
```

**第一遍的逐任务结果（正好演示两类）：**

| 任务 | 结果 | 为什么 |
|---|---|---|
| `apt: nginx present` | **`ok`** | 实验 08 就装过 → 状态已符合 |
| `service: nginx started enabled` | **`ok`** | 已在跑、已 enabled |
| `user: opsuser` | **`changed`** | 用户不存在 |
| `file: /srv/lab20 directory` | **`changed`** | 目录不存在 |
| `copy: index.html` | **`changed`** | 文件不存在 |

**→ 第一遍也可能有大量 `ok`，这不代表"没生效"，而是"本来就不需要改"。**

### 3.8 反例：`shell` 模块永不幂等

```bash
madrough@ubuntulearn:~/lab20$ cat > bad.yaml <<'YAML'
- hosts: lab
  become: true
  tasks:
    - name: 反例：用 shell 模块装包
      shell: apt-get install -y nginx
YAML
madrough@ubuntulearn:~/lab20$ ansible-playbook bad.yaml 2>&1 | tail -3    # changed=1
madrough@ubuntulearn:~/lab20$ ansible-playbook bad.yaml 2>&1 | tail -3    # changed=1  ← 还是 1
```

**根因**：`shell` 模块**不知道"期望状态"**，只要命令执行成功就标 `changed`。而 `apt-get install -y nginx` 在已安装时也返回 0 → **每遍都 changed**。

### 3.9 `--check --diff`：改之前先看会改什么

```bash
madrough@ubuntulearn:~/lab20$ sed -i 's/lab20 deployed by ansible/lab20 DEPLOYED BY ANSIBLE v2/' site.yaml
madrough@ubuntulearn:~/lab20$ ansible-playbook --check --diff site.yaml 2>&1 | tail -18
# TASK [部署首页] ***
# --- before: /srv/lab20/index.html
# +++ after: /srv/lab20/index.html
# @@ -1 +1 @@
# -lab20 deployed by ansible
# +lab20 DEPLOYED BY ANSIBLE v2
# changed: [ubuntulearn]
# PLAY RECAP: ok=6  changed=1

madrough@ubuntulearn:~/lab20$ cat /srv/lab20/index.html
lab20 deployed by ansible          ← ★ 旧内容，--check 真的没写盘
```

### 3.10 真跑 + 再次 check（闭环）

```bash
madrough@ubuntulearn:~/lab20$ ansible-playbook site.yaml 2>&1 | tail -3     # changed=1
madrough@ubuntulearn:~/lab20$ cat /srv/lab20/index.html
lab20 DEPLOYED BY ANSIBLE v2
madrough@ubuntulearn:~/lab20$ ansible-playbook --check site.yaml 2>&1 | tail -3   # changed=0
```

---

## 四、原理

### 4.1 Ansible 是什么：无 agent 的声明式配置管理

| 对比 | Ansible | Puppet/Chef | SaltStack |
|---|---|---|---|
| 目标机要装 agent？ | **不要** | 要 | 要（或要装 minion） |
| 怎么连 | **SSH + Python** | 自带 agent 拉配置 | 消息队列 |
| 语言 | **YAML（playbook）** | 自有 DSL | YAML |

```
控制机（madrough@ubuntulearn）
   │  SSH（免密）
   ▼
目标机（192.168.9.50）
   │  上传模块 → 用 /usr/bin/python3 执行 → 返回 JSON
   ▼
结果汇总成 PLAY RECAP
```

**三条前提**：① SSH 免密 ② 目标机有 Python ③ 提权方式（`become` + sudo）

### 4.2 声明式 vs 命令式（幂等的根源）

| | 命令式（`shell`） | **声明式（模块）** |
|---|---|---|
| 你写的是 | "**执行这个命令**" | "**结果应该长这样**" |
| 谁判断要不要动 | 没人 | **模块自己**（先查现状） |
| 幂等 | ❌ 天然不幂等 | ✅ 天然幂等 |
| 例子 | `apt-get install -y nginx` | `apt: name=nginx state=present` |

**模块内部的"三步走"：**

```
① 读现状（dpkg -l / stat / getent passwd / systemctl is-active）
② 和期望比对
③ 相同 → 返回 ok；不同 → 执行改动 → 返回 changed
```

**所以"幂等"是模块的能力，不是 playbook 的写法。**

### 4.3 每个模块怎么判断"要不要动"（本项实测）

| 模块 | 判断依据 | 注意事项 |
|---|---|---|
| `apt` | dpkg 里有没有这个包、版本是否满足 | 不会重置已装的包 |
| `service` | `systemctl is-active` / `is-enabled` | 服务"起来又挂"会每遍都 changed |
| `user` | `/etc/passwd` 里有没有 | **给了 `password:` 会改密码**（除非给固定哈希） |
| `file` | `stat`：存在性、类型、权限、属主 | 只写你想管的属性，别的不动 |
| **`copy`** | **比对内容哈希 + 权限** | 内容里含时间戳/随机值 → 永远 changed |
| `template` | 渲染后的内容哈希 | 同上 |
| `lineinfile` | 目标行是否已存在/匹配 | 用 `regexp` 精确锚定 |

### 4.4 `PLAY RECAP` 七个字段

| 字段 | 含义 | 常见误读 |
|---|---|---|
| **`ok`** | **任务成功**的总数（**包含 changed**） | ❌ 以为"ok 是没改动的" |
| **`changed`** | 其中**有改动**的子集 | 验收看这个是否为 0 |
| `unreachable` | SSH/连接失败 | 通常是免密或网络问题 |
| `failed` | 任务失败 | 非 0 时 playbook 中断 |
| `skipped` | 被 `when`/`creates` 跳过 | 正常行为 |
| `rescued` | 被 `block/rescue` 捕获 | — |
| `ignored` | `ignore_errors: true` | — |

**所以 `ok=6 changed=3` 的意思是"6 个任务都成功，其中 3 个有改动"**，不是"3 个 ok + 3 个 changed"。

### 4.5 `--check` / `--diff` 的定位（和本项目其他"演练模式"一致）

| 场景 | 演练命令 |
|---|---|
| 改 netplan | `netplan try` / `netplan get all` |
| rsync `--delete` | `rsync -n` |
| 改 nginx | `nginx -t` |
| 改 logrotate | `logrotate -d` |
| 改 Dockerfile | `docker build`（本身就无副作用） |
| **改 playbook** | **`ansible-playbook --check --diff`** |

**局限**：不是所有模块都支持 check 模式；任务间有依赖时会失真（后面的任务读到的是"还没被前面改"的状态）。

### 4.6 `inventory` 与配置优先级

```
ansible.cfg 查找顺序：
  环境变量 ANSIBLE_CONFIG
    > ./ansible.cfg（当前目录）★ 常用
      > ~/.ansible.cfg
        > /etc/ansible/ansible.cfg
```

**"当前目录优先"** → 所以 `cd ~/lab20` 就自动用那份（和实验 19 的 `docker compose` 必须 `cd` 到项目目录同理）。

**inventory 的一行三段：**

```ini
ubuntulearn   ansible_host=192.168.9.50   ansible_user=madrough
└─ 主机名（任意起，日志里显示这个）  └─ 真实地址  └─ 登录用户
```

---

## 五、生产实践

### 5.1 用 role 组织，别写一个巨型 playbook

```
roles/
  nginx/
    tasks/main.yml
    handlers/main.yml
    templates/nginx.conf.j2
    defaults/main.yml
site.yaml          # 只负责"调用哪些 role"
```

**role 的价值：可复用、可组合、变量有层次**（`defaults` < `group_vars` < `host_vars` < 命令行 `-e`）。

### 5.2 `handlers` + `notify`：改了配置才重启

```yaml
    - name: 部署 nginx 配置
      template: {src: nginx.conf.j2, dest: /etc/nginx/nginx.conf}
      notify: reload nginx

  handlers:
    - name: reload nginx
      service: {name: nginx, state: reloaded}
```

**handler 只在被 `notify` 且任务 `changed` 时执行一次**（一个 play 结束才跑）→ **配置没变就不重启服务**。这是幂等在"服务重启"上的体现。

### 5.3 密码/密钥用 Vault，不要明文

```bash
ansible-vault create group_vars/all/vault.yml      # 加密文件
ansible-playbook site.yaml --ask-vault-pass
```

| 手段 | 用途 |
|---|---|
| `ansible-vault` | 加密变量文件（提交到 git 也安全） |
| `--vault-password-file` | 从文件/脚本取密码（CI 里用） |
| 外部密钥管理 | Vault/KMS/云 Secrets Manager（生产首选） |

**绝对不要**：`ansible_become_password` 明文写在 inventory 里（会进 git、会进日志）。

### 5.4 sudoers 只给需要的命令

```yaml
# ❌ 本项为了简单这么写
madrough ALL=(ALL) NOPASSWD:ALL

# ✅ 生产：只给需要的
ansible ALL=(ALL) NOPASSWD: /usr/bin/apt, /usr/bin/systemctl, /usr/bin/tee
```

**更好的做法**：给 Ansible 建一个**专用账号**（`ansible`），只授权它需要的命令，`PermitRootLogin no`。

### 5.5 CI 里跑 `--check` 当作"配置漂移检测"

```bash
# 定期在 CI 里跑只读检查，发现有人手工改过服务器
ansible-playbook site.yaml --check --diff || notify_slack
```

**这就是 IaC（基础设施即代码）的核心价值**：**服务器状态应该和代码一致，不一致就是"漂移"，需要修回来或改代码**。

### 5.6 `--limit` / `--tags` / `--forks`

| 参数 | 用途 |
|---|---|
| `--limit 主机/组` | 只对部分主机执行（灰度发布） |
| `--tags 名字` | 只跑打了标签的任务（`tags: [nginx]`） |
| `--forks N` | 并发数（默认 5，大集群要调大） |
| `--step` | 每个任务前确认（调试用） |
| `-v / -vvv` | 详细输出（排查连接/模块参数问题） |

### 5.7 幂等反模式清单

| 反模式 | 为什么破坏幂等 | 正解 |
|---|---|---|
| `shell:` / `command:` 做状态变更 | 永远 changed | 换模块；实在要用加 `creates:`/`changed_when` |
| `copy: content` 里含时间戳/`{{ ansible_date_time }}` | 每次内容都不同 | 用 `template` 且只在必要时插入动态值 |
| `user: password=` 明文（每次新 salt） | 每次都改 | 给固定哈希（`password: "{{ 'x' \| password_hash('sha512') }}"`，且固定 salt） |
| `file: state=touch` | 每次都更新 mtime | 用 `state=file`/`copy` |
| `lineinfile` 没写 `regexp` | 每次追加一行 | **必须给 `regexp`** |
| 任务里 `git: version=master` | 每次都拉最新 | 钉 tag/commit |

### 5.8 其他

| 项 | 说明 |
|---|---|
| `gather_facts: false` | 不需要 facts 时关掉，能显著加速（每个主机省 1-2 秒） |
| `serial: 2` | 分批滚动执行（避免全量同时重启） |
| `max_fail_percentage` | 允许部分主机失败继续（大集群用） |
| `ansible-pull` | 反向模式：机器定时从 git 拉 playbook 自己执行 |
| `ansible-lint` | 静态检查 playbook 规范（CI 里跑） |

---

## 六、踩坑清单

| # | 坑 | 说明 / 正确做法 |
|---|---|---|
| 1 | 装 `ansible` 全量包 | **300MB+**，根分区从 88% 掉到 95%。**本项用 `ansible-core`（40MB）** |
| 2 | 没有 SSH 免密就跑 playbook | 卡在密码提示 / 报 `Permission denied`。**`ssh-keygen` + `ssh-copy-id` + `BatchMode=yes` 验证** |
| 3 | 忘了配免密 sudo | `become: true` 报 `Missing sudo password`。**sudoers.d + 440 + `visudo -c`** |
| 4 | sudoers 文件权限不是 440 | **sudo 直接忽略这个文件**（静默失效） |
| 5 | 改 sudoers 不 `visudo -c` | 语法错 → **所有 sudo 失效**（可能把自己锁死） |
| 6 | 用 `shell: apt install` 装包 | **永远 `changed=1`**，永不收敛。**用 `apt` 模块** |
| 7 | 以为"第一遍有 `ok` 就是没生效" | **`ok` = 状态已符合**，不是失败。nginx 已装所以第一遍就 ok |
| 8 | 把 `ok` 当成"没有 changed" | **`ok` 是任务成功总数，包含 changed**。`ok=6 changed=3` 是"6 个都成功，其中 3 个有改动" |
| 9 | `copy: content` 里塞时间戳 | 每遍都 changed。**动态内容要小心**，或固定下来 |
| 10 | `lineinfile` 不写 `regexp` | 每遍追加一行。**必须给 `regexp` 锚定** |
| 11 | 在错误目录跑 `ansible-playbook` | 找不到 inventory / 用错了 cfg（因为 `./ansible.cfg` 当前目录优先）。**`cd` 到项目目录** |
| 12 | `ansible_become_password` 明文写 inventory | 会进 git、进日志。**用 vault 或 `-K`** |
| 13 | 把 `--check` 当"一定成功" | 任务间有依赖时会失真；不是所有模块支持 check 模式 |
| 14 | 用 `NOPASSWD:ALL` | 等于给了 root。**本项为教学这么写，生产要按需授权 + 专用账号** |
| 15 | `service: state=started` 每遍都 changed | 说明服务起来了又挂 —— **这是真故障信号**，不是幂等问题 |

---

## 七、命令详解（本项首次出现）

### 7.1 命令与选项

| 命令 / 参数 | 是什么 → 干什么 → 为什么这里用 |
|---|---|
| `ansible --version` | 看 core 版本 + 配置路径 + python 版本 |
| **`ansible -m ping all`** | ad-hoc：对 `all` 组跑 `ping` 模块（**不是 ICMP**）→ 验证 SSH+Python |
| `ansible -m setup 主机` | ad-hoc 收集 facts（能看到所有 `ansible_*` 变量） |
| `ansible all -a 'uptime'` | `-a` 直接给命令（内部走 command 模块） |
| **`ansible-playbook site.yaml`** | 跑 playbook |
| `--syntax-check` | **只查语法不连主机** |
| `--list-tasks` | 列出将要执行的任务（确认解析正确） |
| **`--check`** | **dry run**：算出要改什么但**不落盘** |
| **`--diff`** | 显示文件内容差异（`-`/`+`） |
| `-v / -vv / -vvv` | 输出详细程度（排查连接/参数） |
| `--limit 主机` | 只跑指定主机/组 |
| `--tags` / `--skip-tags` | 按标签过滤任务 |
| `--ask-become-pass`（`-K`） | 交互输入 sudo 密码（没有免密 sudo 时用） |
| `--start-at-task "任务名"` | 从某个任务开始（调试） |
| `--step` | 每个任务前确认 |
| `--forks N` | 并发数 |

### 7.2 配置与清单

| 项 | 说明 |
|---|---|
| **`inventory`** | 主机清单：`[组名]` + `主机名 ansible_host=… ansible_user=…` |
| **`ansible.cfg`** | 配置；**`./ansible.cfg` 优先级高于 `~` 和 `/etc`** |
| `[defaults] inventory = ./inventory` | 指定默认清单 |
| `become: true` | play 级别提权（所有任务用 sudo） |

### 7.3 本项用到的模块

| 模块 | 常用参数 | 判断依据 |
|---|---|---|
| **`apt`** | `name` / `state`（present/latest/absent）/ `update_cache` | dpkg 状态 |
| **`service`** | `name` / `state`（started/stopped/reloaded）/ `enabled` | systemctl |
| **`user`** | `name` / `shell` / `create_home` / `state` | `/etc/passwd` |
| **`file`** | `path` / `state`（directory/file/absent/link）/ `mode` / `owner` | `stat` |
| **`copy`** | `src` 或 `content` / `dest` / `mode` / `owner` | **内容哈希 + 权限** |
| `template` | `src`（.j2）/ `dest` | 渲染后内容哈希 |
| `lineinfile` | `path` / `regexp` / `line` | 是否已匹配 |
| `shell` / `command` | 命令本身 + **`creates` / `changed_when` / `failed_when`** | ❌ 无（永远 changed） |

### 7.4 幂等的"补丁"参数

| 参数 | 作用 |
|---|---|
| **`creates: 路径`** | 该路径**已存在就跳过任务** |
| `removes: 路径` | 该路径**不存在就跳过** |
| `changed_when: 表达式` | 自定义"什么算改动" |
| `failed_when: 表达式` | 自定义"什么算失败" |
| `register: 变量` | 保存任务结果（供后面 `when`/`changed_when` 用） |

---

## 八、验收记录

| 验收项 | 结果 |
|---|---|
| 用 ansible 给本机装 nginx | ✅ `apt: {name: nginx, state: present}` —— **第一遍就 `ok`**（实验 08 已装），这本身演示了幂等 |
| 用 ansible 建用户 | ✅ `user: {name: opsuser}` —— 第一遍 `changed`，第二遍 `ok` |
| **第二遍 `changed=0`（幂等）** | ✅ **`ok=6 changed=0`** |
| 附加：反例对照 | ✅ `shell: apt-get install -y nginx` **两遍都 `changed=1`** → 证明幂等来自模块 |
| 附加：`--check --diff` | ✅ 精准预告 1 个改动 + 显示 diff，**且 `cat` 证实没写盘** |
| 附加：闭环 | ✅ 真跑 `changed=1` → 内容变成 v2 → 再 `--check` 得 `changed=0` |

**面试可用的一句话总结：**

> 我用 ansible-core 写了个 playbook 给本机装 nginx、建运维用户、部署静态页，**第一遍 `changed=3`，第二遍 `changed=0`**，这就是幂等。关键认知是**幂等来自"用模块"而不是"写 playbook"**：`apt`/`user`/`file`/`copy` 这些模块会先查现状再决定动不动，而 `shell: apt-get install` 会每遍都 `changed` —— 因为它的 `changed` 只代表"我执行了命令"。另外我用了 `--check --diff` 做预演，确认只改一个文件而且没落盘，这跟 `netplan try`、`rsync -n`、`nginx -t` 是同一个工程习惯。

---

## 九、遗留 / 后续

- [ ] **`/etc/sudoers.d/90-lab20-nopasswd` 是 `NOPASSWD:ALL`** —— 等于给了 root，**建议实验结束后删掉**（`sudo rm /etc/sudoers.d/90-lab20-nopasswd`）
- [ ] 未写 **`roles/`** 结构（本项只有 5 个任务，扁平足够）
- [ ] 未用 **`handlers` + `notify`**（"改了配置才重启服务"）
- [ ] 未用 **`ansible-vault`**（密码管理）
- [ ] 未做 **`--limit` / `--tags` / `serial`** 的灰度发布演练
- [ ] 未做 **`ansible-lint`** 规范检查
- [ ] 未做**跨主机**管理（只有本机；多机需要再开一台 VM）
- [ ] `opsuser` 是**无密码账号**（`user` 模块没给 `password`）→ 只能 `su` 进去，不能 SSH 登录
- [ ] 未清理 `bad.yaml`（留着当反例）
- [ ] 根分区 **1.1G（89%）** 仍然紧张，`/var/lib/snapd` 的 2.0G 里还有已禁用的旧 revision 没删
