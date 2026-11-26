#!/usr/bin/env bash
set -euo pipefail

source_dir=${1:?缺少解压包路径}
test "$(id -u)" -ne 0
work=$(mktemp -d /work/nginx-smoke.XXXXXX)
cp -R -- "$source_dir" "$work/nginx"
cd -- "$work/nginx"

version=$(./nginxctl -v 2>&1)
[[ $version == 'nginx version: nginx/1.31.10' ]]
./nginxctl -t

# 动态模块默认不启用；额外检查它们能在没有构建依赖的环境加载。
{
    printf 'load_module modules/%s;\n' \
        ngx_http_xslt_filter_module.so ngx_http_image_filter_module.so \
        ngx_mail_module.so ngx_stream_module.so
    cat conf/nginx.conf
} > conf/smoke.conf
./nginxctl -t -c conf/smoke.conf

./nginxctl -g 'daemon off;' -c conf/smoke.conf &
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
