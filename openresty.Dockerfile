# Use the official OpenResty image as a base image
FROM openresty/openresty:1.27.1.1-0-alpine

# Set the working directory
WORKDIR /usr/local/openresty

# Install additional dependencies if needed (e.g., Lua libraries)
#RUN apk add --no-cache \
#    curl \
#    bash \
#    build-base \
#    && apk add --no-cache luarocks \
#    && export PATH=$PATH:/usr/local/bin \
#    && luarocks install lua-resty-http

# Copy nginx.conf vào đúng vị trí (là file, không phải thư mục)
COPY ./nginx.conf /usr/local/openresty/nginx/conf/nginx.conf

# Copy các file Lua
COPY ./redishelper.lua /usr/local/openresty/lualib/
COPY ./http.lua /usr/local/openresty/lualib/resty/
COPY ./http_connect.lua /usr/local/openresty/lualib/resty/
COPY ./http_headers.lua /usr/local/openresty/lualib/resty/
COPY ./service_router.lua /usr/local/openresty/lualib/
COPY ./gateway_routing.lua /usr/local/openresty/lualib/

# Expose the necessary ports
EXPOSE 80 443 8080

# Command to run OpenResty với chỉ định rõ file cấu hình
CMD ["openresty", "-c", "/usr/local/openresty/nginx/conf/nginx.conf", "-g", "daemon off;"]