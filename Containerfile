FROM crystallang/crystal:latest
WORKDIR /src
COPY shard* .
RUN ["shards", "install"]
COPY spec ./spec
COPY src ./src
RUN ["shards", "build", "--error-trace", "--progress"]
