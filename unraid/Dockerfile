# Red Kite — the Unraid agent.
#
# Alpine, because the whole thing is one shell script and the interesting question is how small the
# attack surface is on somebody else's NAS rather than how fast it starts.
#
# **This image needs no network access except to the hub, and no write access to anything.** It is
# handed the host's /proc, /sys and / as read-only mounts, reads them, and posts figures outwards.
# A customer suspicious of a monitoring container on their server is right to be, and everything
# here is arranged so the answer to "what can it do" is short.

FROM alpine:3.22

# bash          the agent is bash, not sh: it uses arrays and [[ ]] throughout
# curl          the one thing that talks to the network
# smartmontools disk health. The reason this container needs capabilities at all
# coreutils     GNU df, stat and date. Busybox's differ in ways that matter for parsing
# gawk          reading Unraid's ini files
# tzdata        so logs are stamped in the operator's own time where they set TZ
RUN apk add --no-cache \
        bash \
        curl \
        smartmontools \
        coreutils \
        gawk \
        tzdata \
    && rm -rf /var/cache/apk/*

COPY redkite-unraid.sh /usr/local/bin/redkite-unraid
RUN chmod 0755 /usr/local/bin/redkite-unraid

# Where the host is shown to us. The template sets these; they are here so that running the image
# by hand without them fails in the one place it should - the mount check - rather than silently
# reporting on the container.
ENV REDKITE_HOST_PROC=/host/proc \
    REDKITE_HOST_SYS=/host/sys \
    REDKITE_HOST_ROOT=/rootfs \
    REDKITE_EMHTTP=/emhttp \
    INTERVAL=300

# Root inside the container, and it genuinely needs to be: SMART reads go through an ioctl that
# wants CAP_SYS_RAWIO, and a capability is only useful to a process that can claim it. Everything
# it can reach from there is read-only, and it holds no capability it was not explicitly given.
#
# It is worth being plain about this in the file rather than in a document nobody opens: this
# container can read the raw block devices of the machine it is on. It cannot write to them, it
# cannot reach anything but the hub, and the agent beside this file is short enough to read.
USER root

# No healthcheck on purpose.
#
# **The hub is the healthcheck.** If this container stops, check-ins stop, and the hub raises an
# incident and tells somebody - which is the entire product. A HEALTHCHECK here would let Docker
# quietly restart a container that is failing to report, hiding exactly the thing that is meant to
# be noticed.
HEALTHCHECK NONE

ENTRYPOINT ["/usr/local/bin/redkite-unraid"]
