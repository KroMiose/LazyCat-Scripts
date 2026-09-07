# 常用命令备忘录 (Common Commands Cheatsheet) 📚

这里是 KroMiose 偶尔会经常用到的一些命令片段，整理在此供备忘查阅。

---

## Git 相关 (Git Related)

### 保存 Git 登录凭据 (Caching Git Credentials)

每次 `git push` 或 `git pull` 都要输入密码是不是很烦？可以使用 Git 的 `credential.helper` 功能来帮你记住密码。

#### 1. 临时缓存 (推荐，安全)

这个方法会将你的密码在内存中缓存一段时间（默认 15 分钟）。对于大多数人来说，这是安全性和便利性的最佳平衡点。

```sh
# 开启缓存功能
git config --global credential.helper cache

# (可选) 设置缓存时间，比如1小时 (3600秒)
git config --global credential.helper 'cache --timeout=3600'
```

当你下次输入密码后，它就会在指定时间内被记住。

#### 2. 永久存储 (方便但有风险)

这个方法会将你的用户名和密码**以明文形式**存储在你的用户主目录下的一个文件里 (`~/.git-credentials`)。虽然非常方便，但任何能访问你电脑文件的人都能看到你的密码。

> 🚨 **安全警告:** 请只在完全受你控制且足够安全的个人电脑上使用此方法。不要在共享服务器或公共电脑上使用！

```sh
# 开启永久存储功能
git config --global credential.helper store
```

---

## Docker 相关 (Docker Related)

### 启动 Qdrant 向量数据库 (Starting Qdrant Vector Database)

这里提供了两种启动 Qdrant 的方式，一种是基础的，另一种是带有安全密钥的，主人可以按需选择哦。

#### 1. 基础启动 (无密钥)

一个用于本地开发和测试的 Qdrant 启动命令。它会将数据持久化到当前目录下的一个文件夹中，并且会在 Docker 服务启动时自动重启。

```sh
docker run --name qdrant-basic \
  -p 127.0.0.1:6333:6333 \
  -p 127.0.0.1:6334:6334 \
  -v "$(pwd)/qdrant_storage:/qdrant/storage:z" \
  --restart unless-stopped \
  -d qdrant/qdrant
```

**命令详解:**

- `--name qdrant-basic`: 给容器起一个好记的名字 (`qdrant-basic`)。
- `-p 127.0.0.1:6333:6333 -p 127.0.0.1:6334:6334`: 将本机的 6333 和 6334 端口映射到容器的对应端口。
- `-v "$(pwd)/qdrant_storage:/qdrant/storage:z"`: 将 **当前目录** 下的 `qdrant_storage` 文件夹挂载到容器内的 `/qdrant/storage` 目录，这样即使容器被删除，数据也不会丢失。
- `--restart unless-stopped`: 除非手动停止，否则容器总是在 Docker 服务启动时自动重启，保证服务可用性。
- `-d`: 后台运行容器。
- `qdrant/qdrant`: 使用官方的 Qdrant 镜像。

#### 2. 启动并启用 API 密钥

此命令在基础版之上增加了 API 密钥保护，所有请求都需要提供正确的密钥才能访问。

> 🚨 **安全提示:** 请务必将 `your-secret-api-key` 替换为您自己的强安全密钥！

```sh
docker run --name qdrant-secure \
  -p 127.0.0.1:6333:6333 \
  -p 127.0.0.1:6334:6334 \
  -v "$(pwd)/qdrant_storage:/qdrant/storage:z" \
  -e QDRANT__SERVICE__API_KEY='your-secret-api-key' \
  --restart unless-stopped \
  -d qdrant/qdrant
```

**新增命令详解:**

- `-e QDRANT__SERVICE__API_KEY=...`: 通过设置环境变量来启用并配置 API 密钥。Qdrant 会自动读取这个变量并开启安全验证。

**连接示例 (使用 curl):**

```sh
# 替换成你的密钥
export QDRANT_API_KEY="your-secret-api-key"

# 查询所有 collections
curl -X GET "http://localhost:6333/collections" \
  -H "api-key: ${QDRANT_API_KEY}"
```

### 启动 PostgreSQL 数据库

一个用于本地开发和测试的 PostgreSQL 启动命令。它会将数据持久化，并配置好用户名、密码和数据库名。

```sh
# 运行 PostgreSQL 15 容器
# 请务必将 'mysecretpassword' 替换为您自己的强密码！
docker run --name my-postgres \
  -e POSTGRES_USER=myuser \
  -e POSTGRES_PASSWORD=mysecretpassword \
  -e POSTGRES_DB=mydb \
  -p 127.0.0.1:5432:5432 \
  -v my-postgres-data:/var/lib/postgresql/data \
  --restart unless-stopped \
  -d postgres:15
```

**命令详解:**

- `--name my-postgres`: 给容器起一个好记的名字。
- `-e POSTGRES_...`: 设置环境变量来初始化数据库。
  - `POSTGRES_USER`: 设置数据库用户名。
  - `POSTGRES_PASSWORD`: 设置用户密码。**【重要】**
  - `POSTGRES_DB`: 创建一个指定名称的数据库。
- `-p 127.0.0.1:5432:5432`: 将本机的 5432 端口映射到容器的 5432 端口。
- `-v my-postgres-data:/var/lib/postgresql/data`: 创建一个名为 `my-postgres-data` 的 Docker 卷 (volume) 并挂载到容器内 PG 的数据目录，这样即使容器被删除，数据也不会丢失。
- `--restart unless-stopped`: 除非手动停止，否则容器总是在 Docker 服务启动时自动重启。
- `-d`: 后台运行容器。
- `postgres:15`: 使用官方的 PostgreSQL 15 镜像。

**连接示例:**

```sh
psql -h localhost -p 5432 -U myuser -d mydb
```

### 清理 Docker 资源

清理掉所有未使用的容器、网络、镜像（包括悬空和未被使用的）。

```sh
docker system prune -a --volumes
```

---
