FROM composer:2@sha256:d8f6343d3fae98107426bc49163ccad46ef85aabd4a27d80a74401fab4aba332 AS publisher
ARG SATIS_REF=7346cc900efbdc8c30547d01769509f6baae2196
RUN apk add --no-cache python3 \
    && git clone https://github.com/composer/satis.git /satis \
    && git -C /satis checkout "$SATIS_REF" \
    && composer install --working-dir=/satis --no-dev --no-interaction --no-plugins --no-scripts --prefer-dist
COPY publish.py packages.json /publisher/
ENTRYPOINT ["python3", "/publisher/publish.py"]

FROM caddy:2-alpine@sha256:5f5c8640aae01df9654968d946d8f1a56c497f1dd5c5cda4cf95ab7c14d58648 AS server
COPY Caddyfile /etc/caddy/Caddyfile
EXPOSE 8080
