FROM kong:latest

USER root

# Cài đặt công cụ phát triển
RUN apt-get update && \
    apt-get install -y git unzip

# Sao chép plugin tùy chỉnh vào container
COPY ./my-rate-limiter /usr/local/share/lua/5.1/kong/plugins/my-rate-limiter

# Cài đặt biến môi trường
ENV KONG_LUA_PACKAGE_PATH=/usr/local/openresty/lualib/?.lua;;

USER kong