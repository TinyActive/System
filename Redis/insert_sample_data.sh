#!/bin/bash
# ------------------------------------------------------------
# Script mẫu để chèn dữ liệu vào Redis nhằm kiểm tra sự đồng bộ
# của các node (cluster) trong hệ thống.
#
# Yêu cầu:
#   - Đã cài đặt redis-cli (kiểm tra bằng lệnh: redis-cli --version)
#
# Cách sử dụng:
#   Nếu redis của bạn có password, hãy xuất biến môi trường REDIS_PASSWORD:
#       export REDIS_PASSWORD=your_redis_password
#
#   Sau đó chạy script:
#       ./insert_sample_data.sh host1:port1 host2:port2 ...
#
# Ví dụ:
#   export REDIS_PASSWORD=123456
#   ./insert_sample_data.sh 192.168.1.100:6379 192.168.1.101:6379 192.168.1.102:6379
#
# Script sẽ:
#   1. Chèn một key mẫu vào node đầu tiên.
#   2. Chờ một vài giây để dữ liệu được đồng bộ (nếu hệ thống có cơ chế replication).
#   3. Kiểm tra xem key đó có tồn tại và có giá trị đúng trên các node khác không.
# ------------------------------------------------------------

# Kiểm tra số lượng tham số
if [ "$#" -lt 1 ]; then
    echo "Usage: $0 host:port [host:port ...]"
    echo "Nếu redis của bạn có password, hãy xuất biến môi trường REDIS_PASSWORD trước khi chạy script."
    exit 1
fi

# Nếu có password được thiết lập qua biến môi trường, thêm tùy chọn -a cho redis-cli
AUTH_PARAM=""
if [ ! -z "$REDIS_PASSWORD" ]; then
    AUTH_PARAM="-a ${REDIS_PASSWORD}"
    echo "Sử dụng password từ biến môi trường REDIS_PASSWORD."
fi

# Cấu hình dữ liệu mẫu
KEY_PREFIX="sample"
SAMPLE_DATA="HelloRedisCluster"
TIMESTAMP=$(date +%s)
KEY="${KEY_PREFIX}:${TIMESTAMP}"

echo "Chèn dữ liệu mẫu: key = ${KEY}, value = ${SAMPLE_DATA}"

# Lấy node đầu tiên (sẽ dùng để chèn dữ liệu mẫu)
FIRST_NODE=$1
FIRST_HOST=$(echo $FIRST_NODE | cut -d':' -f1)
FIRST_PORT=$(echo $FIRST_NODE | cut -d':' -f2)

echo "Chèn dữ liệu vào node đầu tiên: ${FIRST_HOST}:${FIRST_PORT}"
redis-cli -h "${FIRST_HOST}" -p "${FIRST_PORT}" ${AUTH_PARAM} SET "${KEY}" "${SAMPLE_DATA}"
if [ $? -ne 0 ]; then
    echo "Lỗi: Không thể chèn dữ liệu vào ${FIRST_HOST}:${FIRST_PORT}"
    exit 1
fi

# Đợi một chút để dữ liệu có thể được đồng bộ (nếu hệ thống có cơ chế replication)
SLEEP_TIME=2
echo "Đợi ${SLEEP_TIME} giây để dữ liệu được đồng bộ..."
sleep "${SLEEP_TIME}"

# Kiểm tra dữ liệu trên tất cả các node đã chỉ định
echo "Bắt đầu kiểm tra dữ liệu trên các node..."
for NODE in "$@"
do
    HOST=$(echo "${NODE}" | cut -d':' -f1)
    PORT=$(echo "${NODE}" | cut -d':' -f2)
    echo "Kiểm tra key ${KEY} trên node ${HOST}:${PORT}..."
    VALUE=$(redis-cli -h "${HOST}" -p "${PORT}" ${AUTH_PARAM} GET "${KEY}")
    
    if [ "${VALUE}" == "${SAMPLE_DATA}" ]; then
        echo "Thành công: Node ${HOST}:${PORT} có dữ liệu đúng."
    else
        echo "Lỗi: Node ${HOST}:${PORT} không có dữ liệu hoặc dữ liệu không khớp."
    fi
done

echo "Hoàn thành kiểm tra dữ liệu mẫu."