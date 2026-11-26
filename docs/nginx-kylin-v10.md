# Nginx 1.31.10 离线部署：银河麒麟 V10（Halberd）x86_64

目标为银河麒麟高级服务器 V10（Halberd）`x86_64`。构建和断网测试使用 Rocky Linux 8 `x86_64`，不是麒麟镜像。**Rocky 通过不代表麒麟实机已验证。**

## 在 GitHub Actions 构建

1. 将项目推送到 GitHub 仓库，确保工作流文件已进入默认分支。
2. 在 **Actions → Build Nginx 1.31.10 for Kylin V10 (x86_64) → Run workflow** 选择 `main` 后运行，无需填写参数。CI 下载源码及其独立 PGP 签名，使用固定指纹的 Nginx 上游公钥验签；验签失败时不会解包或编译。
3. 工作流在 GitHub 托管 runner 下载、构建、打包，并在无外网的干净 Rocky 容器中检查模块加载、配置和 HTTP 响应。测试通过后，在该次运行的 **Artifacts** 下载 `nginx-1.31.10-kylin-v10-halberd-x86_64`，从外层 ZIP 取出 `.tar.gz` 与 `.tar.gz.sha256`，一起传入离线服务器。保持 `.tar.gz` 原样，以保留可执行权限。

构建以 Rocky 8 标签解析出的镜像摘要运行，同次测试使用同一摘要；镜像标签及 RPM 仓库内容仍会更新。包内 `BUILD-INFO.txt` 记录实际镜像、源码哈希、构建参数和 RPM 版本，不承诺跨次构建逐字节一致。

## 在目标服务器解包运行

需要 Linux `x86_64`、Bash、`tar`、`sha256sum`，以及与 Rocky Linux 8 构建结果兼容的系统 glibc（构建基线 2.28）和 x86_64 ELF 加载器。其余采集到的 ELF 依赖放在 `lib/`，详见 `BUNDLED-LIBS.tsv`。部署和运行不需要在线软件源。

推荐解包到 `/usr/local/nginx-1.31.10-kylin-v10-halberd-x86_64`。在两个产物文件所在目录，以管理员身份执行以下命令；将 `nginxsvc` 替换为服务器上已有的非 root 服务账号。解包目录已存在时会停止，不覆盖旧文件。

```bash
pkg=nginx-1.31.10-kylin-v10-halberd-x86_64
dest="/usr/local/$pkg"
service_user=nginxsvc

test "$(id -u "$service_user")" -gt 0 &&
    sha256sum -c "$pkg.tar.gz.sha256" &&
    mkdir -m 0755 -- "$dest" &&
    tar --no-same-owner -xzf "$pkg.tar.gz" -C "$dest" --strip-components=1 &&
    chown -R -- "$service_user" "$dest/logs" "$dest/run" "$dest/tmp" &&
    runuser -u "$service_user" -- "$dest/nginxctl" -V &&
    runuser -u "$service_user" -- "$dest/nginxctl" -t &&
    runuser -u "$service_user" -- "$dest/nginxctl" &&
    curl --noproxy '*' -fsS http://127.0.0.1:8080/healthz
```

`/usr/local` 只是推荐路径；没有管理员权限时，也可以解包到自己的目录，用普通用户直接执行 `./nginxctl -t` 和 `./nginxctl`。部署到 `/usr/local` 后，配置由管理员维护，重载和停止仍使用启动服务的账号。

健康检查应返回 `offline-nginx-ok`。`curl` 仅用于测试，不是服务依赖。校验或配置检查失败时，不要继续启动；遇到 `GLIBC_* not found` 或 `cannot open shared object file`，请记录完整错误及 `getconf GNU_LIBC_VERSION` 输出，不要替换麒麟系统的 glibc。

- `nginxctl` 负责定位包内库和运行前缀，请通过它运行，不要直接调用 `sbin/nginx`。
- 配置在 `conf/nginx.conf`，默认只监听 `127.0.0.1:8080`；按需修改端口和监听地址，部署证书、代理地址等由实际环境决定。
- 重载：`./nginxctl -t && ./nginxctl -s reload`。停止：`./nginxctl -s quit`。该包不注册 systemd 服务。
- 卸载：确认进程已经退出后，备份自定义配置、日志和站点数据，再删除解压目录。不覆盖 `/etc/nginx` 或 `/usr/sbin/nginx`。

## 与参考构建参数的差异

采用独立目录布局和 PCRE2，IPv6 无需旧的 `--with-ipv6` 开关。保留 SSL、HTTP/2 等常用功能；XSLT、图像滤镜、Mail 和 Stream 编译为动态模块，默认不启用，按需在配置顶层用 `load_module modules/<文件名>;` 加载。此构建不包含 Perl、Google perftools 或 HTTP degradation 模块。
