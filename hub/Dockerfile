FROM oven/bun:1.4.4-alpine

WORKDIR /app

# tzdata 供 TZ 环境变量生效；libstdc++ 供 better-sqlite3-multiple-ciphers 原生模块运行。
RUN apk add --no-cache tzdata libstdc++

COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --production

COPY hub/src ./hub/src
COPY packages/record ./packages/record
COPY schema/record.schema.json ./schema/record.schema.json
COPY plugins/agent-sessions/filters.ts ./plugins/agent-sessions/filters.ts

RUN mkdir -p /data && chown bun:bun /data && chmod 700 /data

ENV RA_HUB_MODE=server \
    RA_SECRET_BACKEND=sealed-file \
    RA_DATA_DIR=/data \
    RA_MASTER_KEY_FILE=/run/secrets/tacit_master_key \
    RA_LAN_PORT=47824

VOLUME ["/data"]
EXPOSE 47824

USER bun
CMD ["bun", "hub/src/cli.ts", "run"]
