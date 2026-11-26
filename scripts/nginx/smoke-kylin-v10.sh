#!/usr/bin/env bash
set -euo pipefail

source_dir=${1:?缺少解压包路径}
test "$(id -u)" -ne 0
unset LD_LIBRARY_PATH
default_dir=/usr/local/nginx
cp -R -- "$source_dir" "$default_dir"
test ! -e "$default_dir/nginxctl"

# 从包之外检查默认前缀，不传 -p 或 -c。
cd /
version=$("$default_dir/sbin/nginx" -v 2>&1)
[[ $version == 'nginx version: nginx/1.31.10' ]]
"$default_dir/sbin/nginx" -t

work=$(mktemp -d /work/nginx-smoke.XXXXXX)
cp -R -- "$source_dir" "$work/nginx"
cd -- "$work/nginx"
./sbin/nginx -p "$PWD/" -t

# 不加载外部模块，直接验证内置模块的指令和变量。
cat > conf/smoke.conf <<'NGINX'
events {}

http {
    server {
        listen 127.0.0.1:8080;
        location = /healthz { return 200 "offline-nginx-ok\n"; }
        location /xslt { xslt_types application/xml; }
        location /image { image_filter test; }
    }
}

mail {
    auth_http 127.0.0.1:8080/mail-auth;
    server {
        listen 127.0.0.1:1025;
        protocol smtp;
    }
}

stream {
    log_format preread '$ssl_preread_protocol';
    server {
        listen 127.0.0.1:18443;
        ssl_preread on;
        access_log logs/stream-access.log preread;
        proxy_pass 127.0.0.1:8080;
    }
}
NGINX
./sbin/nginx -p "$PWD/" -t -c conf/smoke.conf

./sbin/nginx -p "$PWD/" -g 'daemon off;' -c conf/smoke.conf &
nginx_pid=$!
cleanup() {
    kill -QUIT "$nginx_pid" 2>/dev/null || true
    wait "$nginx_pid" 2>/dev/null || true
    rm -rf -- "$work"
}
trap cleanup EXIT

probe() {
    local response
    response=$(timeout 2 bash -c '
        exec 3<>/dev/tcp/127.0.0.1/8080
        printf "GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n" >&3
        cat <&3
    ' 2>/dev/null) || return 1
    [[ $response == 'HTTP/1.1 200 '* && $response == *$'\r\n\r\noffline-nginx-ok' ]]
}

for ((attempt = 0; attempt < 20; attempt++)); do
    if probe; then
        echo '断网环境 HTTP 验证通过'
        exit 0
    fi
    kill -0 "$nginx_pid" 2>/dev/null || break
    sleep 0.2
done
cat logs/error.log >&2
exit 1
