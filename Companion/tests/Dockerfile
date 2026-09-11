FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-venv python3-gi gir1.2-atspi-2.0 gir1.2-gtk-3.0 \
    at-spi2-core dbus-x11 xvfb xauth openbox xterm x11-utils ca-certificates \
    fonts-dejavu-core && rm -rf /var/lib/apt/lists/*
COPY Companion /workspace/Companion
COPY ProtocolFixtures /workspace/ProtocolFixtures
RUN python3 -m venv --system-site-packages /opt/companion && \
    /opt/companion/bin/pip install '/workspace/Companion[test]'
ENV PATH="/opt/companion/bin:$PATH"
WORKDIR /workspace/Companion
CMD ["xvfb-run", "-a", "-s", "-screen 0 1280x800x24 -nolisten tcp", "dbus-run-session", "--", "bash", "tests/run-linux-integration.sh"]
