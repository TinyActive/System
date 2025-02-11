#### TRiển khai nhanh Mô hình  Redis Cluster


##### Cài đặt triển khai từ redis có sẵn 1 máy chủ

```sh
bash Redis_Cluster_install.sh
```

```sh
export REDIS_PASSWORD=foobared && ./insert_sample_data.sh 10.130.0.7:6379 10.130.0.5:6379 10.130.0.6:6379 10.130.0.3:6379
```

Đọc thêm ở đây: [Hướng dẫn triển khai](https://blog.manhtuong.net/trien-khai-nhanh-redis-cluster-tu-single-redis/)