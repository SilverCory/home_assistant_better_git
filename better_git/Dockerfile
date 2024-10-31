ARG BUILD_FROM
FROM $BUILD_FROM

# Setup base
RUN apk add --no-cache jq curl git openssh-client inotify-tools

# Home Assistant CLI
ARG BUILD_ARCH
ARG CLI_VERSION
RUN curl -Lso /usr/bin/ha \
        "https://github.com/home-assistant/cli/releases/download/${CLI_VERSION}/ha_${BUILD_ARCH}" \
    && chmod a+x /usr/bin/ha

# Copy data
COPY data/template.gitignore /
COPY data/run.sh /
RUN chmod a+x /run.sh

ENV SUPERVISOR_TOKEN;

# Set shell
CMD [ "/run.sh" ]