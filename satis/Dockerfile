FROM composer:2 AS publisher
ARG SATIS_REF=7346cc900efbdc8c30547d01769509f6baae2196
RUN apk add --no-cache python3 \
    && git clone https://github.com/composer/satis.git /satis \
    && git -C /satis checkout "$SATIS_REF" \
    && composer install --working-dir=/satis --no-dev --no-interaction --no-plugins --no-scripts --prefer-dist
COPY publish.py packages.json /publisher/
ENTRYPOINT ["python3", "/publisher/publish.py"]

FROM caddy:2-alpine AS server
COPY Caddyfile /etc/caddy/Caddyfile
EXPOSE 8080
