FROM oven/bun:1.4.4-alpine
WORKDIR /app
COPY src ./src
ENV TACIT_RELAY_DB=/data/relay.db PORT=8787
VOLUME /data
EXPOSE 8787
USER bun
CMD ["bun", "src/bun.ts"]
