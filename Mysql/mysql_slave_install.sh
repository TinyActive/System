#!/bin/bash
set -e

##############################################
# THÔNG SỐ MÁY CHỦ VÀ MÁY SLAVE – CÀI ĐẶT THEO YÊU CẦU
##############################################

# Thông tin máy chủ MASTER (đã có MySQL cài sẵn)
MASTER_IP="10.10.10.1"
MASTER_SSH_USER="root"
MASTER_SSH_PASSWORD="555555555555"
MASTER_MYSQL_USER="root"
MASTER_MYSQL_PASSWORD="123456789"

# Thông tin máy chủ SLAVE (máy mới, chưa cài MySQL)
SLAVE_IP="10.10.10.2"
SLAVE_SSH_USER="root"
SLAVE_SSH_PASSWORD="987654321"

# Thông tin replication (tạo user mới dùng cho replication)
REPL_USER="replica"
REPL_PASSWORD="replica_pass"

# Tên file dump tạm thời
DUMP_FILE="/root/master_dump.sql"
LOCAL_DUMP="/tmp/master_dump.sql"

##############################################
# HÀM HỖ TRỢ: chạy lệnh từ xa dùng sshpass
##############################################

run_remote() {
    # Tham số: $1 = IP, $2 = user, $3 = password, $4 = lệnh cần chạy
    sshpass -p "$3" ssh -o StrictHostKeyChecking=no "$2@$1" "$4"
}

run_remote_scp() {
    # Tham số: $1 = password, $2 = source, $3 = destination (user@host:dest)
    sshpass -p "$1" scp -o StrictHostKeyChecking=no "$2" "$3"
}

##############################################
# KIỂM TRA CÀI ĐẶT sshpass (nếu chưa có thì cài đặt)
##############################################

if ! command -v sshpass >/dev/null 2>&1; then
    echo "[*] sshpass chưa được cài đặt. Đang cài đặt..."
    sudo apt-get update && sudo apt-get install -y sshpass
fi

##############################################
# 1. CẤU HÌNH MASTER: bật Binary Logging & đặt server-id
##############################################

echo "[*] Cấu hình MySQL Master trên $MASTER_IP ..."

# Đường dẫn file cấu hình MySQL (Ubuntu 20.04 thường dùng file này)
MASTER_MY_CNF="/etc/mysql/mysql.conf.d/mysqld.cnf"

# Thêm/đảm bảo có server-id = 1
run_remote "$MASTER_IP" "$MASTER_SSH_USER" "$MASTER_SSH_PASSWORD" \
    "grep -q '^[[:space:]]*server-id' $MASTER_MY_CNF || sed -i '/\[mysqld\]/a server-id = 1' $MASTER_MY_CNF"

# Bật binary log (nếu chưa có)
run_remote "$MASTER_IP" "$MASTER_SSH_USER" "$MASTER_SSH_PASSWORD" \
    "grep -q '^[[:space:]]*log_bin' $MASTER_MY_CNF || sed -i '/\[mysqld\]/a log_bin = /var/log/mysql/mysql-bin.log' $MASTER_MY_CNF"

# (Tùy chọn) Đặt binlog_format = ROW
run_remote "$MASTER_IP" "$MASTER_SSH_USER" "$MASTER_SSH_PASSWORD" \
    "grep -q '^[[:space:]]*binlog_format' $MASTER_MY_CNF || sed -i '/\[mysqld\]/a binlog_format = ROW' $MASTER_MY_CNF"

# Khởi động lại MySQL Master để áp dụng cấu hình
echo "[*] Khởi động lại MySQL trên MASTER..."
run_remote "$MASTER_IP" "$MASTER_SSH_USER" "$MASTER_SSH_PASSWORD" "systemctl restart mysql"

##############################################
# 2. TẠO REPLICATION USER TRÊN MASTER
##############################################

echo "[*] Tạo replication user '$REPL_USER' trên MASTER..."
CREATE_USER_CMD="CREATE USER IF NOT EXISTS '$REPL_USER'@'%' IDENTIFIED WITH mysql_native_password BY '$REPL_PASSWORD';"
GRANT_CMD="GRANT REPLICATION SLAVE ON *.* TO '$REPL_USER'@'%';"
FLUSH_CMD="FLUSH PRIVILEGES;"

CMD="$CREATE_USER_CMD $GRANT_CMD $FLUSH_CMD"
run_remote "$MASTER_IP" "$MASTER_SSH_USER" "$MASTER_SSH_PASSWORD" \
    "mysql -u$MASTER_MYSQL_USER -p$MASTER_MYSQL_PASSWORD -e \"$CMD\""

##############################################
# 3. LẤY MASTER STATUS (FILE & POSITION)
##############################################

echo "[*] Lấy trạng thái MASTER..."
MASTER_STATUS=$(run_remote "$MASTER_IP" "$MASTER_SSH_USER" "$MASTER_SSH_PASSWORD" \
    "mysql -u$MASTER_MYSQL_USER -p$MASTER_MYSQL_PASSWORD -e 'SHOW MASTER STATUS\G'")
echo "$MASTER_STATUS"

# Lấy giá trị File và Position (dựa trên định dạng của lệnh SHOW MASTER STATUS)
MASTER_LOG_FILE=$(echo "$MASTER_STATUS" | grep 'File:' | awk '{print $2}')
MASTER_LOG_POS=$(echo "$MASTER_STATUS" | grep 'Position:' | awk '{print $2}')

if [ -z "$MASTER_LOG_FILE" ] || [ -z "$MASTER_LOG_POS" ]; then
    echo "[ERROR] Không lấy được thông tin MASTER STATUS. Kiểm tra lại cấu hình MySQL Master."
    exit 1
fi

echo "[*] MASTER_LOG_FILE: $MASTER_LOG_FILE, MASTER_LOG_POS: $MASTER_LOG_POS"

# lấy thông tin Version Mysql Trên máy chủ đã có
echo "[*] Lấy thông tin version Mysql..."

MYSQL_VERSION=$(run_remote "$MASTER_IP" "$MASTER_SSH_USER" "$MASTER_SSH_PASSWORD" \
    "mysql -V | sed -E 's/.*Distrib ([0-9]+\.[0-9]+\.[0-9]+).*/\1/'")
echo " Phiên bản Mysql có Version là $MYSQL_VERSION"

if [ -z "$MYSQL_VERSION" ]; then
    echo "[ERROR] Không lấy được thông tin MYSQL_VERSION. Kiểm tra lại cấu hình MySQL Master hoặc kết nối mạng."
    exit 1
fi

##############################################
# 4. TẠO DUMP TOÀN BỘ DATABASE TRÊN MASTER
##############################################

echo "[*] Tạo dump toàn bộ database trên MASTER..."
DUMP_CMD="mysqldump -u$MASTER_MYSQL_USER -p$MASTER_MYSQL_PASSWORD --all-databases --master-data=1 --single-transaction --quick --lock-tables=false > $DUMP_FILE"
run_remote "$MASTER_IP" "$MASTER_SSH_USER" "$MASTER_SSH_PASSWORD" "$DUMP_CMD"

# Copy file dump từ MASTER về máy điều khiển tạm thời
echo "[*] Copy dump file từ MASTER về máy cục bộ..."
run_remote_scp "$MASTER_SSH_PASSWORD" "$MASTER_SSH_USER@$MASTER_IP:$DUMP_FILE" "$LOCAL_DUMP"

##############################################
# 5. CÀI ĐẶT VÀ CẤU HÌNH MYSQL TRÊN SLAVE
##############################################

echo "[*] Cài đặt MySQL trên SLAVE ($SLAVE_IP)..."
# Cài MySQL nếu chưa có (sử dụng DEBIAN_FRONTEND=noninteractive để tránh prompt)
run_remote "$SLAVE_IP" "$SLAVE_SSH_USER" "$SLAVE_SSH_PASSWORD" \
    "apt-get update && DEBIAN_FRONTEND=noninteractive apt install -y mysql-server=$MYSQL_VERSION"

# Cấu hình file MySQL cho SLAVE: đặt server-id khác (ví dụ: 2)
SLAVE_MY_CNF="/etc/mysql/mysql.conf.d/mysqld.cnf"
run_remote "$SLAVE_IP" "$SLAVE_SSH_USER" "$SLAVE_SSH_PASSWORD" \
    "grep -q '^[[:space:]]*server-id' $SLAVE_MY_CNF || sed -i '/\[mysqld\]/a server-id = 2' $SLAVE_MY_CNF"

# Khởi động lại MySQL trên SLAVE
echo "[*] Khởi động lại MySQL trên SLAVE..."
run_remote "$SLAVE_IP" "$SLAVE_SSH_USER" "$SLAVE_SSH_PASSWORD" "systemctl restart mysql"

# Copy file dump từ máy cục bộ sang SLAVE
echo "[*] Copy dump file từ máy cục bộ sang SLAVE..."
run_remote_scp "$SLAVE_SSH_PASSWORD" "$LOCAL_DUMP" "$SLAVE_SSH_USER@$SLAVE_IP:$DUMP_FILE"

# Import dump vào MySQL trên SLAVE
echo "[*] Import dump file vào MySQL trên SLAVE..."
run_remote "$SLAVE_IP" "$SLAVE_SSH_USER" "$SLAVE_SSH_PASSWORD" "mysql < $DUMP_FILE"

##############################################
# 6. CẤU HÌNH REPLICATION TRÊN SLAVE
##############################################

echo "[*] Cấu hình replication trên SLAVE..."
CHANGE_MASTER_CMD="CHANGE MASTER TO MASTER_HOST='$MASTER_IP', MASTER_USER='$REPL_USER', MASTER_PASSWORD='$REPL_PASSWORD', MASTER_LOG_FILE='$MASTER_LOG_FILE', MASTER_LOG_POS=$MASTER_LOG_POS;"
START_SLAVE_CMD="START SLAVE;"
run_remote "$SLAVE_IP" "$SLAVE_SSH_USER" "$SLAVE_SSH_PASSWORD" \
    "mysql -e \"$CHANGE_MASTER_CMD $START_SLAVE_CMD\""

# Kiểm tra trạng thái slave
echo "[*] Kiểm tra trạng thái slave trên SLAVE..."
SLAVE_STATUS=$(run_remote "$SLAVE_IP" "$SLAVE_SSH_USER" "$SLAVE_SSH_PASSWORD" "mysql -e 'SHOW SLAVE STATUS\G'")
echo "$SLAVE_STATUS"

##############################################
# 7. DỌN DẸP FILE TẠM
##############################################

echo "[*] Dọn dẹp file dump tạm thời trên MASTER, SLAVE và máy cục bộ..."
run_remote "$MASTER_IP" "$MASTER_SSH_USER" "$MASTER_SSH_PASSWORD" "rm -f $DUMP_FILE"
run_remote "$SLAVE_IP" "$SLAVE_SSH_USER" "$SLAVE_SSH_PASSWORD" "rm -f $DUMP_FILE"
rm -f "$LOCAL_DUMP"

echo "[*] Triển khai master-slave replication hoàn tất."