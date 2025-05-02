FROM kong:latest

USER root

RUN apt-get update && \
    apt-get install -y git unzip

COPY ./my-rate-limiter /usr/local/share/lua/5.1/kong/plugins/my-rate-limiter

USER kong