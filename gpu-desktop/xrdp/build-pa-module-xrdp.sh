cd /usr/src/pulseaudio-module-xrdp || exit 1
echo "=== attempt: minimal config.h for PULSE_CONFIG_DIR ==="
mkdir -p /usr/src/pa-config
cat > /usr/src/pa-config/config.h <<'EOF'
#define PACKAGE_VERSION "16.1"
#define PACKAGE_NAME "pulseaudio"
#define PACKAGE "pulseaudio"
#define HAVE_STDINT_H 1
#define HAVE_UNISTD_H 1
#define HAVE_SYS_SOCKET_H 1
#define HAVE_SYS_UN_H 1
#define HAVE_STRING_H 1
#define HAVE_STDLIB_H 1
#define HAVE_ERRNO_H 1
#define HAVE_PWD_H 1
#define HAVE_GRP_H 1
#define HAVE_FCNTL_H 1
#define HAVE_SYS_STAT_H 1
#define HAVE_SYS_TYPES_H 1
#define HAVE_DLFCN_H 1
#define HAVE_GETOPT_H 1
#define HAVE_SIGACTION 1
#define HAVE_PTHREAD 1
#define HAVE_LIBPTHREAD 1
#define HAVE_SHM 1
#define HAVE_MMAP 1
#define HAVE_STRNDUP 1
#define HAVE_GETADDRINFO 1
#define HAVE_POLL_H 1
#define HAVE_SYSLOG_H 1
#define HAVE_SYS_MMAN_H 1
#define HAVE_SYS_SHM_H 1
#define HAVE_SYS_WAIT_H 1
#define HAVE_ARPA_INET_H 1
#define HAVE_NETINET_IN_H 1
#define HAVE_NETDB_H 1
#define HAVE_SYS_TIME_H 1
#define HAVE_TIME_H 1
EOF
make clean > /dev/null 2>&1
rm -f config.status
if ./configure PULSE_DIR=/usr/src/pulseaudio-16.1 PULSE_CONFIG_DIR=/usr/src/pa-config > /tmp/gpu-desk/cfg.log 2>&1; then
    echo "configure OK"
    if make > /tmp/gpu-desk/make.log 2>&1; then
        echo "make OK"
        make install > /tmp/gpu-desk/install.log 2>&1 && echo "INSTALL_OK" || echo "install failed"
        ls -la /var/lib/xrdp-pulseaudio-installer/ 2>/dev/null
        ls -la /usr/libexec/pulseaudio-module-xrdp/ /etc/xdg/autostart/*xrdp* 2>/dev/null
    else
        echo "make FAILED:"; tail -25 /tmp/gpu-desk/make.log
    fi
else
    echo "configure FAILED:"; tail -20 /tmp/gpu-desk/cfg.log
fi
