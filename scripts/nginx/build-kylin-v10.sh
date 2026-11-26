#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
version=1.31.10
name="nginx-${version}-kylin-v10-halberd-x86_64"
url="https://nginx.org/download/nginx-${version}.tar.gz"
out=${1:?缺少输出目录}
: "${NGINX_SOURCE_SHA256:?缺少源码 SHA-256}"
: "${BUILD_IMAGE:?缺少构建镜像标识}"
: "${BUILD_COMMIT:?缺少构建提交标识}"
[[ $NGINX_SOURCE_SHA256 =~ ^[a-fA-F0-9]{64}$ ]] || { echo '源码 SHA-256 必须为 64 位十六进制字符' >&2; exit 1; }
[[ $(uname -m) == x86_64 ]] || { echo '仅支持 x86_64 构建' >&2; exit 1; }
# shellcheck disable=SC1091
source /etc/os-release
[[ $ID == rocky && ${VERSION_ID%%.*} == 8 ]] || { echo '构建需要 Rocky Linux 8' >&2; exit 1; }

mkdir -p -- "$out"
out=$(cd -- "$out" && pwd -P)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
cd -- "$work"

dnf install -y --enablerepo=powertools --setopt=install_weak_deps=False \
    /usr/bin/curl gcc make binutils tar gzip openssl-devel pcre2-devel zlib-devel libxml2-devel libxslt-devel gd-devel

curl --fail --silent --show-error --location --retry 3 --proto '=https' --proto-redir '=https' \
    --output source.tar.gz "$url"
printf '%s  source.tar.gz\n' "${NGINX_SOURCE_SHA256,,}" | sha256sum --check --strict

tar -xzf source.tar.gz
cd -- "nginx-$version"
options=(
    --prefix=/opt/offline-nginx
    --sbin-path=sbin/nginx --modules-path=modules --conf-path=conf/nginx.conf
    --error-log-path=logs/error.log --http-log-path=logs/access.log
    --pid-path=run/nginx.pid --lock-path=run/nginx.lock
    --http-client-body-temp-path=tmp/client_body --http-proxy-temp-path=tmp/proxy
    --http-fastcgi-temp-path=tmp/fastcgi --http-scgi-temp-path=tmp/scgi
    --http-uwsgi-temp-path=tmp/uwsgi
    --with-file-aio --with-http_ssl_module --with-http_v2_module
    --with-http_realip_module --with-http_addition_module
    --with-http_xslt_module=dynamic --with-http_image_filter_module=dynamic
    --with-http_sub_module --with-http_dav_module --with-http_flv_module
    --with-http_mp4_module --with-http_gunzip_module --with-http_gzip_static_module
    --with-http_random_index_module --with-http_secure_link_module --with-http_slice_module
    --with-http_auth_request_module --with-mail=dynamic --with-mail_ssl_module
    --with-pcre-jit --with-stream=dynamic --with-stream_ssl_module --with-debug
    '--with-cc-opt=-O2 -g -pipe -Wall -D_FORTIFY_SOURCE=2 -fstack-protector-strong'
    '--with-ld-opt=-Wl,-z,relro -Wl,-z,now'
)
./configure "${options[@]}"
make -j"$(nproc)"
make install DESTDIR="$work/stage"

bundle="$work/$name"
mv -- "$work/stage/opt/offline-nginx" "$bundle"
mkdir -p -- "$bundle"/{lib,run,logs,tmp,licenses}
install -m 0755 "$repo/scripts/nginx/nginxctl.sh" "$bundle/nginxctl"
install -m 0644 "$repo/configs/nginx/nginx.conf" "$bundle/conf/nginx.conf"
install -m 0644 "$repo/docs/nginx-kylin-v10.md" "$bundle/README.md"
install -m 0644 LICENSE "$bundle/licenses/nginx-LICENSE"

# 保留目标系统的 glibc 和加载器；其余 ELF 依赖按 SONAME 携带。
shopt -s nullglob
modules=("$bundle"/modules/*.so)
((${#modules[@]} == 4)) || { echo '预期构建 4 个动态模块' >&2; exit 1; }
ldd "$bundle/sbin/nginx" "${modules[@]}" > "$bundle/BUILD-LINKS.txt"
if grep -Fq 'not found' "$bundle/BUILD-LINKS.txt"; then
    cat "$bundle/BUILD-LINKS.txt" >&2
    exit 1
fi
printf 'SONAME\tRPM\n' > "$bundle/BUNDLED-LIBS.tsv"
while read -r soname path; do
    case "$soname" in
        ld-linux*.so.*|libc.so.6|libm.so.6|libmvec.so.1|libpthread.so.0|libdl.so.2|librt.so.1|libresolv.so.2|libutil.so.1|libanl.so.1|libnss_*.so.2)
            continue ;;
    esac
    real_path=$(readlink -f -- "$path")
    rpm_name=$(rpm -qf --qf '%{NAME}' "$real_path")
    rpm_version=$(rpm -qf --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$real_path")
    [[ $rpm_name != glibc ]] || { echo "未识别的 glibc 依赖: $soname" >&2; exit 1; }
    install -m 0644 -- "$real_path" "$bundle/lib/$soname"
    printf '%s\t%s\n' "$soname" "$rpm_version" >> "$bundle/BUNDLED-LIBS.tsv"
    if [[ ! -d $bundle/licenses/$rpm_name ]]; then
        mkdir -- "$bundle/licenses/$rpm_name"
        while IFS= read -r license; do
            [[ -f $license ]] || continue
            cp -L --parents -- "$license" "$bundle/licenses/$rpm_name/"
        done < <(rpm -qL "$rpm_name")
    fi
done < <(awk '$2 == "=>" && $3 ~ /^\// {print $1, $3}' "$bundle/BUILD-LINKS.txt" | sort -u)

{
    printf 'target=Kylin Linux Advanced Server V10 (Halberd) x86_64\n'
    printf 'build_image=%s\ncommit=%s\nsource=%s\nsource_sha256=%s\n' \
        "$BUILD_IMAGE" "$BUILD_COMMIT" "$url" "${NGINX_SOURCE_SHA256,,}"
    printf 'configure:'
    printf ' %q' "${options[@]}"
    printf '\n\nRPM packages in build environment:\n'
    rpm -qa | sort
} > "$bundle/BUILD-INFO.txt"

tar -C "$work" --owner=0 --group=0 --numeric-owner -czf "$out/$name.tar.gz" "$name"
cd -- "$out"
sha256sum "$name.tar.gz" > "$name.tar.gz.sha256"
