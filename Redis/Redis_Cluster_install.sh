#!/bin/bash
#---------------------------------------------------------------------
# Script triển khai 2 cụm Redis (Master-Slave) trên 4 máy chủ và kiểm tra
# trạng thái replication của cả master và slave.
#
# --- Cụm 1 ---
# Master: Server1
# Slave:  Server2
#
# --- Cụm 2 ---
# Master: Server3
# Slave:  Server4
#
# Thông tin các máy chủ:
#
# Server1 (Master cụm 1):
#   IP: 10.10.10.1
#   SSH: user: root, pass: 555555555555
#
# Server2 (Slave cụm 1):
#   IP: 10.10.10.2
#   SSH: user: root, pass: 987654321
#
# Server3 (Master cụm 2):
#   IP: 10.10.10.3
#   SSH: user: root, pass: 987654321
#
# Server4 (Slave cụm 2):
#   IP: 10.10.10.4
#   SSH: user: root, pass: 987654321
#
# Quy trình:
#   1. Phát hiện phiên bản Redis trên Server1.
#   2. Kiểm tra/cài đặt Redis trên tất cả các máy chủ theo phiên bản đó.
#   3. Cấu hình vai trò cho từng máy chủ:
#         - Master: không có dòng "slaveof"
#         - Slave: thêm dòng "slaveof <MASTER_IP> 6379"
#      Kèm theo cấu hình bảo mật (requirepass, masterauth) và bind 0.0.0.0.
#   4. Restart dịch vụ Redis trên từng máy chủ.
#   5. Kiểm tra trạng thái replication:
#         - Trên các máy chủ slave: hiển thị "master_link_status"
#         - Trên các máy chủ master: in đầy đủ thông tin replication (role, số lượng slave,...)
#
# Yêu cầu:
#   - sshpass phải được cài đặt trên máy chủ chạy script này.
#
# CẢNH BÁO: Script sẽ thay đổi file cấu hình và cài đặt phần mềm trên các máy chủ.
#---------------------------------------------------------------------

set -e

check_sshpass() {
  if ! command -v sshpass &>/dev/null; then
    echo ">> sshpass chưa được cài đặt. Đang tiến hành cài đặt..."
    if command -v apt-get &>/dev/null; then
      apt-get update && apt-get install -y sshpass
    elif command -v yum &>/dev/null; then
      yum install -y sshpass
    else
      echo ">> Không tìm thấy package manager (apt-get hoặc yum). Vui lòng cài đặt sshpass theo cách thủ công."
      exit 1
    fi
  else
    echo ">> sshpass đã được cài đặt."
  fi
}

# Gọi hàm kiểm tra sshpass trước khi thực hiện các tác vụ khác
check_sshpass



###############################
# Thông số cấu hình chung
###############################
REDIS_PASSWORD="foobared"
REDIS_PORT="6379"
# File cấu hình mặc định sau khi cài Redis từ source
REDIS_CONF="/etc/redis/redis.conf"

###############################
# Thông tin các máy chủ
###############################
# --- Cụm 1 ---
MASTER1_IP="10.130.0.7"
MASTER1_SSH_USER="root"
MASTER1_SSH_PASS="9V23dYJk5ZqDdNGU"

SLAVE1_IP="10.130.0.5"
SLAVE1_SSH_USER="root"
SLAVE1_SSH_PASS="9V23dYJk5ZqDdNGU"

# --- Cụm 2 ---
MASTER2_IP="10.130.0.6"
MASTER2_SSH_USER="root"
MASTER2_SSH_PASS="9V23dYJk5ZqDdNGU"

SLAVE2_IP="10.130.0.3"
SLAVE2_SSH_USER="root"
SLAVE2_SSH_PASS="9V23dYJk5ZqDdNGU"

#########################################
# Hàm: detect_redis_version
# Mục đích: Lấy phiên bản Redis đang chạy trên một máy chủ.
#########################################
detect_redis_version() {
  local server_ip="$1"
  local ssh_user="$2"
  local ssh_pass="$3"
  local version_line
  version_line=$(sshpass -p "$ssh_pass" ssh -o StrictHostKeyChecking=no ${ssh_user}@${server_ip} "redis-server --version" 2>/dev/null || echo "")
  if [ -z "$version_line" ]; then
      echo "none"
  else
      # Ví dụ: "Redis server v=6.0.9 ..."
      local version
      version=$(echo "$version_line" | awk '{for(i=1;i<=NF;i++) { if ($i ~ /^v=/) { split($i, a, "="); print a[2]; break } } }')
      echo "$version"
  fi
}

#########################################
# Hàm: build_and_install_redis
# Mục đích: Build và cài đặt Redis từ source với phiên bản chỉ định.
#########################################
build_and_install_redis() {
  local server_ip="$1"
  local ssh_user="$2"
  local ssh_pass="$3"
  local target_version="$4"
  echo ">> [${server_ip}] Build và cài đặt Redis version ${target_version} từ source..."
  sshpass -p "$ssh_pass" ssh -o StrictHostKeyChecking=no ${ssh_user}@${server_ip} bash <<EOF
apt-get update && apt-get install -y build-essential tcl wget
cd /tmp
wget http://download.redis.io/releases/redis-${target_version}.tar.gz
tar xzf redis-${target_version}.tar.gz
cd redis-${target_version}
make
make install
# Tạo thư mục cho cấu hình nếu chưa có và copy file cấu hình mẫu
[ ! -d /etc/redis ] && mkdir -p /etc/redis
cp redis.conf /etc/redis/redis.conf
# Tạo file unit systemd để quản lý dịch vụ Redis
cat <<EOT > /etc/systemd/system/redis.service
[Unit]
Description=Redis In-Memory Data Store
After=network.target

[Service]
ExecStart=/usr/local/bin/redis-server /etc/redis/redis.conf
ExecStop=/usr/local/bin/redis-cli shutdown
Restart=always

[Install]
WantedBy=multi-user.target
EOT
systemctl daemon-reload
systemctl enable redis.service
systemctl start redis.service
EOF
}

#########################################
# Hàm: check_and_install_redis
# Mục đích: Kiểm tra sự tồn tại của Redis trên server; nếu chưa có thì cài đặt
#            từ source với phiên bản target_version. Nếu đã cài nhưng phiên bản
#            không khớp, sẽ đưa ra cảnh báo.
#########################################
check_and_install_redis() {
   local server_ip="$1"
   local ssh_user="$2"
   local ssh_pass="$3"
   local target_version="$4"
   echo ">> [${server_ip}] Kiểm tra sự tồn tại của Redis..."
   local version_line
   version_line=$(sshpass -p "$ssh_pass" ssh -o StrictHostKeyChecking=no ${ssh_user}@${server_ip} "redis-server --version" 2>/dev/null || echo "")
   if [ -z "$version_line" ]; then
       echo ">> [${server_ip}] Chưa cài Redis. Tiến hành cài đặt Redis version ${target_version} từ source..."
       build_and_install_redis "$server_ip" "$ssh_user" "$ssh_pass" "$target_version"
   else
       local installed_version
       installed_version=$(echo "$version_line" | awk '{for(i=1;i<=NF;i++) { if ($i ~ /^v=/) { split($i, a, "="); print a[2]; break } } }')
       if [ "$installed_version" != "$target_version" ]; then
           echo ">> [${server_ip}] Cảnh báo: Phiên bản Redis hiện tại ($installed_version) KHÔNG khớp với phiên bản mong muốn ($target_version)."
           # Có thể bổ sung logic cập nhật/hạ cấp nếu cần.
       else
           echo ">> [${server_ip}] Redis version $installed_version đã được cài đặt."
       fi
   fi
}

#########################################
# Hàm: configure_redis_role
# Mục đích: Cấu hình file cấu hình Redis cho vai trò master hoặc slave.
#   - Nếu role là "master": đảm bảo không có dòng "slaveof".
#   - Nếu role là "slave": thêm dòng "slaveof <MASTER_IP> <REDIS_PORT>".
# Đồng thời, thêm các thông số bảo mật (requirepass, masterauth) và bind 0.0.0.0.
#########################################
configure_redis_role() {
  local server_ip="$1"
  local ssh_user="$2"
  local ssh_pass="$3"
  local role="$4"         # "master" hoặc "slave"
  local master_ip="$5"    # Chỉ dùng khi role là "slave"
  echo ">> [${server_ip}] Cấu hình Redis với vai trò ${role}..."
  sshpass -p "$ssh_pass" ssh -o StrictHostKeyChecking=no ${ssh_user}@${server_ip} bash <<EOF
# Xác định file cấu hình Redis
if [ -f /etc/redis/redis.conf ]; then
  CONF_FILE="/etc/redis/redis.conf"
elif [ -f /etc/redis.conf ]; then
  CONF_FILE="/etc/redis.conf"
else
  echo "Không tìm thấy file cấu hình Redis trên ${server_ip}!"
  exit 1
fi

# Sao lưu file cấu hình hiện tại
cp \$CONF_FILE \${CONF_FILE}.bak

# Loại bỏ các dòng liên quan đến slaveof, requirepass và masterauth cũ (nếu có)
sed -i '/^slaveof/d' \$CONF_FILE
sed -i '/^requirepass/d' \$CONF_FILE
sed -i '/^masterauth/d' \$CONF_FILE

# Cấu hình bảo mật
echo "requirepass ${REDIS_PASSWORD}" >> \$CONF_FILE
echo "masterauth ${REDIS_PASSWORD}" >> \$CONF_FILE

# Nếu vai trò là slave thì thêm dòng "slaveof"
if [ "$role" = "slave" ]; then
  echo "slaveof ${master_ip} ${REDIS_PORT}" >> \$CONF_FILE
fi

# Đảm bảo Redis lắng nghe trên mọi interface
sed -i '/^bind/d' \$CONF_FILE
echo "bind 0.0.0.0" >> \$CONF_FILE

# Restart dịch vụ Redis
if command -v systemctl >/dev/null 2>&1; then
  if systemctl status redis.service >/dev/null 2>&1; then
    systemctl restart redis.service
  elif systemctl status redis-server >/dev/null 2>&1; then
    systemctl restart redis-server
  else
    echo "Không tìm thấy dịch vụ Redis qua systemctl. Vui lòng restart Redis thủ công."
  fi
else
  if service redis status >/dev/null 2>&1; then
    service redis restart
  elif service redis-server status >/dev/null 2>&1; then
    service redis-server restart
  else
    echo "Không tìm thấy dịch vụ Redis qua lệnh service. Vui lòng restart Redis thủ công."
  fi
fi
EOF
}

#########################################
# Hàm: check_replication_status
# Mục đích: Kiểm tra trạng thái replication trên một máy chủ (thường dùng cho slave).
# Lấy thông tin từ "info replication" và lọc các dòng liên quan.
#########################################
check_replication_status() {
  local server_ip="$1"
  local ssh_user="$2"
  local ssh_pass="$3"
  echo ">> [${server_ip}] Kiểm tra trạng thái replication (Slave)..."
  sshpass -p "$ssh_pass" ssh -o StrictHostKeyChecking=no ${ssh_user}@${server_ip} bash <<EOF
echo "----- Replication Status trên ${server_ip} (Slave) -----"
redis-cli -a ${REDIS_PASSWORD} info replication | grep -E "role:|master_link_status:"
echo "---------------------------------------------------------"
EOF
}

#########################################
# Hàm: check_master_status
# Mục đích: Kiểm tra trạng thái replication trên máy chủ master.
# In đầy đủ thông tin từ "info replication" để xem số lượng slave kết nối,…
#########################################
check_master_status() {
  local server_ip="$1"
  local ssh_user="$2"
  local ssh_pass="$3"
  echo ">> [${server_ip}] Kiểm tra trạng thái replication (Master)..."
  sshpass -p "$ssh_pass" ssh -o StrictHostKeyChecking=no ${ssh_user}@${server_ip} bash <<EOF
echo "----- Replication Status trên ${server_ip} (Master) -----"
redis-cli -a ${REDIS_PASSWORD} info replication
echo "---------------------------------------------------------"
EOF
}

#########################################
# Quy trình chính
#########################################
echo "======================================="
echo "Bắt đầu triển khai 2 cụm Redis (Master-Slave)"
echo "======================================="

# 1. Phát hiện phiên bản Redis trên Server1 (Master của cụm 1)
target_version=$(detect_redis_version "${MASTER1_IP}" "${MASTER1_SSH_USER}" "${MASTER1_SSH_PASS}")
if [ "$target_version" = "none" ]; then
  echo "Error: Không phát hiện được phiên bản Redis trên ${MASTER1_IP}. Vui lòng kiểm tra lại."
  exit 1
fi
echo ">> Phiên bản Redis trên ${MASTER1_IP}: $target_version"

# 2. Kiểm tra / cài đặt Redis trên tất cả các máy chủ theo phiên bản target
for server in "${MASTER1_IP}:${MASTER1_SSH_USER}:${MASTER1_SSH_PASS}" \
              "${SLAVE1_IP}:${SLAVE1_SSH_USER}:${SLAVE1_SSH_PASS}" \
              "${MASTER2_IP}:${MASTER2_SSH_USER}:${MASTER2_SSH_PASS}" \
              "${SLAVE2_IP}:${SLAVE2_SSH_USER}:${SLAVE2_SSH_PASS}"; do
  IFS=":" read -r ip user pass <<< "$server"
  check_and_install_redis "$ip" "$user" "$pass" "$target_version"
done

# 3. Cấu hình vai trò cho từng máy chủ
# --- Cụm 1 ---
echo ">> Cấu hình cụm 1:"
configure_redis_role "${MASTER1_IP}" "${MASTER1_SSH_USER}" "${MASTER1_SSH_PASS}" "master"
configure_redis_role "${SLAVE1_IP}" "${SLAVE1_SSH_USER}" "${SLAVE1_SSH_PASS}" "slave" "${MASTER1_IP}"

# --- Cụm 2 ---
echo ">> Cấu hình cụm 2:"
configure_redis_role "${MASTER2_IP}" "${MASTER2_SSH_USER}" "${MASTER2_SSH_PASS}" "master"
configure_redis_role "${SLAVE2_IP}" "${SLAVE2_SSH_USER}" "${SLAVE2_SSH_PASS}" "slave" "${MASTER2_IP}"

# Chờ vài giây để dịch vụ khởi động lại
sleep 5

# 4. Kiểm tra trạng thái replication:
echo "======================================="
echo "Kiểm tra trạng thái replication trên các Slave"
echo "======================================="
check_replication_status "${SLAVE1_IP}" "${SLAVE1_SSH_USER}" "${SLAVE1_SSH_PASS}"
check_replication_status "${SLAVE2_IP}" "${SLAVE2_SSH_USER}" "${SLAVE2_SSH_PASS}"

echo "======================================="
echo "Kiểm tra trạng thái replication trên các Master"
echo "======================================="
check_master_status "${MASTER1_IP}" "${MASTER1_SSH_USER}" "${MASTER1_SSH_PASS}"
check_master_status "${MASTER2_IP}" "${MASTER2_SSH_USER}" "${MASTER2_SSH_PASS}"

echo "======================================="
echo "Triển khai 2 cụm Redis (Master-Slave) và kiểm tra trạng thái hoàn tất."