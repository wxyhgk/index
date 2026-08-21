#!/bin/bash
# 创建一个本地自签的代码签名证书，用来给 Index 提供**稳定的签名身份**。
#
# 为什么需要：ad-hoc 签名（codesign -s -）没有身份信息，TCC（隐私授权数据库）
# 只能按二进制的 cdhash 记录「屏幕录制」授权 —— 代码一改哈希就变，授权立刻失效。
# 换成固定证书后，TCC 记的是「bundle ID + 证书指纹」，重新构建不影响授权。
#
# 只需要跑一次。之后 build.sh 会自动找到它。
set -euo pipefail

CERT_NAME="Index Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
    echo "证书「${CERT_NAME}」已存在，无需重复创建。"
    exit 0
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

cat > "$WORK_DIR/openssl.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no

[dn]
CN = Index Dev

[v3]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
EOF

echo "==> 生成自签证书"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$WORK_DIR/openssl.cnf" \
    -keyout "$WORK_DIR/key.pem" \
    -out "$WORK_DIR/cert.pem" 2>/dev/null

# macOS 的 security 只认老的 PKCS#12 加密算法，OpenSSL 3 默认用 AES-256 会导入失败，
# 所以这里显式降级到 3DES/SHA1。密码只是临时用于导入。
P12_PASS="index-import"
openssl pkcs12 -export \
    -certpbe PBE-SHA1-3DES \
    -keypbe PBE-SHA1-3DES \
    -macalg sha1 \
    -inkey "$WORK_DIR/key.pem" \
    -in "$WORK_DIR/cert.pem" \
    -out "$WORK_DIR/cert.p12" \
    -passout "pass:$P12_PASS" 2>/dev/null

echo "==> 导入登录钥匙串（可能会弹窗要求输入登录密码）"
security import "$WORK_DIR/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" -A -T /usr/bin/codesign

echo "==> 标记为可信的代码签名证书"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK_DIR/cert.pem"

echo
echo "完成。现在跑 ./build.sh 会自动用「${CERT_NAME}」签名。"
echo "撤销方式：打开「钥匙串访问」，在登录钥匙串里删掉名为「${CERT_NAME}」的证书。"
