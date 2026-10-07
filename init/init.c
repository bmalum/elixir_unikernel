/*
 * /init for the Elixir image.
 *
 * Replaces erlexec + the release shell script + an init system. It
 *   1. mounts devtmpfs/proc (if the kernel didn't),
 *   2. configures lo and the first ethernet interface from the kernel
 *      command line (uniapp.ip=A.B.C.D/N uniapp.gw=A.B.C.D uniapp.dns=A.B.C.D),
 *   3. writes an inetrc so OTP uses its pure-Erlang resolver (no inet_gethost),
 *   4. execs beam.smp with the argv erlexec would have produced.
 *
 * Kernel command line switches:
 *   uniapp.mode=iex   (default)  boot into IEx
 *   uniapp.mode=app              boot straight into the application, -noshell
 *   uniapp.tls_host=example.com  enable the DNS + TLS client probes
 *
 * Statically linked against musl; no libc beyond what musl provides.
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <stdarg.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <net/route.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <dirent.h>
#include <time.h>

#ifndef RELEASE_ROOT
#define RELEASE_ROOT "/rel"
#endif
#ifndef RELEASE_NAME
#define RELEASE_NAME "uniapp"
#endif
#ifndef RELEASE_VSN
#define RELEASE_VSN "0.1.0"
#endif
#ifndef ERTS_VSN
#error "ERTS_VSN must be defined (e.g. -DERTS_VSN=\"17.1.1\")"
#endif

static char cmdline[4096];

static void logmsg(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logmsg(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    fputs("[init] ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    va_end(ap);
}

static void read_cmdline(void) {
    int fd = open("/proc/cmdline", O_RDONLY);
    if (fd < 0) return;
    ssize_t n = read(fd, cmdline, sizeof cmdline - 1);
    close(fd);
    if (n > 0) {
        cmdline[n] = 0;
        char *nl = strchr(cmdline, '\n');
        if (nl) *nl = 0;
    }
}

/* value of key=... from cmdline, or NULL. Returned string is heap-allocated
   (never freed; init runs once). */
static const char *param(const char *key) {
    char buf[256];
    size_t kl = strlen(key);
    const char *p = cmdline;
    while (*p) {
        while (*p == ' ') p++;
        const char *end = p;
        while (*end && *end != ' ') end++;
        if ((size_t)(end - p) > kl && !memcmp(p, key, kl) && p[kl] == '=') {
            size_t vl = end - p - kl - 1;
            if (vl >= sizeof buf) vl = sizeof buf - 1;
            memcpy(buf, p + kl + 1, vl);
            buf[vl] = 0;
            return strdup(buf);
        }
        p = end;
    }
    return NULL;
}

static void mount_fs(const char *src, const char *tgt, const char *type) {
    mkdir(tgt, 0755);
    if (mount(src, tgt, type, 0, NULL) < 0 && errno != EBUSY)
        logmsg("mount %s on %s: %s (continuing)", type, tgt, strerror(errno));
}

static int if_set_flags(int s, const char *name, short flags) {
    struct ifreq ifr;
    memset(&ifr, 0, sizeof ifr);
    strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
    if (ioctl(s, SIOCGIFFLAGS, &ifr) < 0) return -1;
    ifr.ifr_flags |= flags;
    return ioctl(s, SIOCSIFFLAGS, &ifr);
}

static int if_set_addr(int s, const char *name, unsigned long req, in_addr_t a) {
    struct ifreq ifr;
    memset(&ifr, 0, sizeof ifr);
    strncpy(ifr.ifr_name, name, IFNAMSIZ - 1);
    struct sockaddr_in *sin = (struct sockaddr_in *)&ifr.ifr_addr;
    sin->sin_family = AF_INET;
    sin->sin_addr.s_addr = a;
    return ioctl(s, req, &ifr);
}

/* first interface that is not lo */
static int find_eth(int s, char *out, size_t outsz) {
    struct ifconf ifc;
    struct ifreq reqs[16];
    ifc.ifc_len = sizeof reqs;
    ifc.ifc_req = reqs;
    if (ioctl(s, SIOCGIFCONF, &ifc) == 0) {
        int n = ifc.ifc_len / sizeof(struct ifreq);
        for (int i = 0; i < n; i++)
            if (strcmp(reqs[i].ifr_name, "lo") != 0) {
                snprintf(out, outsz, "%s", reqs[i].ifr_name);
                return 0;
            }
    }
    /* SIOCGIFCONF only lists configured (addressed) interfaces on Linux; fall back to sysfs */
    DIR *d = opendir("/sys/class/net");
    if (d) {
        struct dirent *e;
        while ((e = readdir(d))) {
            if (e->d_name[0] == '.' || !strcmp(e->d_name, "lo")) continue;
            snprintf(out, outsz, "%s", e->d_name);
            closedir(d);
            return 0;
        }
        closedir(d);
    }
    /* last resort: common names */
    const char *guess[] = {"eth0", "enp0s1", "ens3", "virtio0", NULL};
    for (int i = 0; guess[i]; i++) {
        struct ifreq ifr;
        memset(&ifr, 0, sizeof ifr);
        strncpy(ifr.ifr_name, guess[i], IFNAMSIZ - 1);
        if (ioctl(s, SIOCGIFFLAGS, &ifr) == 0) {
            snprintf(out, outsz, "%s", guess[i]);
            return 0;
        }
    }
    return -1;
}

static void setup_net(void) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) { logmsg("socket: %s", strerror(errno)); return; }

    if (if_set_addr(s, "lo", SIOCSIFADDR, htonl(INADDR_LOOPBACK)) < 0)
        logmsg("lo addr: %s", strerror(errno));
    if (if_set_flags(s, "lo", IFF_UP | IFF_RUNNING) < 0)
        logmsg("lo up: %s", strerror(errno));

    const char *ip = param("uniapp.ip");
    if (!ip) ip = "10.0.2.15/24";
    const char *gw = param("uniapp.gw");
    if (!gw) gw = "10.0.2.2";

    char ipbuf[64];
    snprintf(ipbuf, sizeof ipbuf, "%s", ip);
    int prefix = 24;
    char *slash = strchr(ipbuf, '/');
    if (slash) { *slash = 0; prefix = atoi(slash + 1); }

    char eth[IFNAMSIZ] = "eth0";
    if (find_eth(s, eth, sizeof eth) < 0) {
        logmsg("no ethernet interface found; skipping network");
        close(s);
        return;
    }

    struct in_addr a, g;
    if (inet_pton(AF_INET, ipbuf, &a) != 1) { logmsg("bad ip %s", ipbuf); close(s); return; }
    in_addr_t mask = prefix == 0 ? 0 : htonl(~0u << (32 - prefix));

    if (if_set_addr(s, eth, SIOCSIFADDR, a.s_addr) < 0) logmsg("%s addr: %s", eth, strerror(errno));
    if (if_set_addr(s, eth, SIOCSIFNETMASK, mask) < 0) logmsg("%s netmask: %s", eth, strerror(errno));
    if (if_set_flags(s, eth, IFF_UP | IFF_RUNNING) < 0) logmsg("%s up: %s", eth, strerror(errno));

    if (inet_pton(AF_INET, gw, &g) == 1) {
        struct rtentry rt;
        memset(&rt, 0, sizeof rt);
        struct sockaddr_in *dst = (struct sockaddr_in *)&rt.rt_dst;
        struct sockaddr_in *gwa = (struct sockaddr_in *)&rt.rt_gateway;
        struct sockaddr_in *msk = (struct sockaddr_in *)&rt.rt_genmask;
        dst->sin_family = gwa->sin_family = msk->sin_family = AF_INET;
        gwa->sin_addr = g;
        rt.rt_flags = RTF_UP | RTF_GATEWAY;
        rt.rt_dev = eth;
        if (ioctl(s, SIOCADDRT, &rt) < 0) logmsg("default route: %s", strerror(errno));
    }
    logmsg("net: %s %s/%d gw %s", eth, ipbuf, prefix, gw);
    close(s);
}

static void write_file(const char *path, const char *content) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { logmsg("write %s: %s", path, strerror(errno)); return; }
    write(fd, content, strlen(content));
    close(fd);
}

static void setup_inetrc(void) {
    const char *dns = param("uniapp.dns");
    if (!dns) dns = "10.0.2.3";
    struct in_addr d;
    if (inet_pton(AF_INET, dns, &d) != 1) { logmsg("bad dns %s", dns); return; }
    unsigned char *b = (unsigned char *)&d.s_addr;
    char buf[512];
    mkdir("/etc", 0755);
    /* inetrc: pure-Erlang resolver, no inet_gethost port program. */
    snprintf(buf, sizeof buf,
             "%%%% generated by /init\n"
             "{lookup, [file, dns]}.\n"
             "{host, {127,0,0,1}, [\"localhost\"]}.\n"
             "{edns, 0}.\n");
    write_file("/etc/inetrc", buf);
    setenv("ERL_INETRC", "/etc/inetrc", 1);
    /* Nameservers go in resolv.conf, not inetrc: inet_db (re)loads
       /etc/resolv.conf periodically and a *missing* file clears the
       nameserver list (inet_db.erl "No file - clear content"). */
    snprintf(buf, sizeof buf, "nameserver %u.%u.%u.%u\n", b[0], b[1], b[2], b[3]);
    write_file("/etc/resolv.conf", buf);
    write_file("/etc/hosts", "127.0.0.1 localhost\n");
}

int main(void) {
    mount_fs("proc", "/proc", "proc");
    mount_fs("devtmpfs", "/dev", "devtmpfs");
    mount_fs("sysfs", "/sys", "sysfs");
    read_cmdline();

    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    logmsg("elixir_unikernel init, uptime %ld.%03ld s", (long)t0.tv_sec, t0.tv_nsec / 1000000);

    setup_net();
    setup_inetrc();

    const char *mode = param("uniapp.mode");
    int iex = !(mode && !strcmp(mode, "app"));

    const char *root = RELEASE_ROOT;
    static char bindir[256], boot[256], sysconfig[256], libdir[256];
    snprintf(bindir, sizeof bindir, "%s/erts-%s/bin", root, ERTS_VSN);
    snprintf(boot, sizeof boot, "%s/releases/%s/start", root, RELEASE_VSN);
    snprintf(sysconfig, sizeof sysconfig, "%s/releases/%s/sys", root, RELEASE_VSN);
    snprintf(libdir, sizeof libdir, "%s/lib", root);

    setenv("ROOTDIR", root, 1);
    setenv("BINDIR", bindir, 1);          /* beam.smp needs this to find erl_child_setup */
    setenv("EMU", "beam", 1);
    setenv("PROGNAME", "erl", 1);
    setenv("HOME", "/", 1);
    setenv("LANG", "C.UTF-8", 1);
    setenv("TERM", "dumb", 0);            /* serial console; no terminfo in the image */
    setenv("RELEASE_ROOT", root, 1);
    setenv("RELEASE_NAME", RELEASE_NAME, 1);
    setenv("RELEASE_VSN", RELEASE_VSN, 1);
    setenv("RELEASE_MODE", "embedded", 1);
    setenv("RELEASE_NODE", RELEASE_NAME, 1);
    setenv("RELEASE_SYS_CONFIG", sysconfig, 1);
    setenv("ERL_CRASH_DUMP", "/dev/null", 1);
    setenv("KERNEL_CMDLINE", cmdline, 1);

    static char beam[256];
    snprintf(beam, sizeof beam, "%s/beam.smp", bindir);

    const char *argv[48];
    int n = 0;
    argv[n++] = beam;
    argv[n++] = "-Bd";                    /* emulator flag (erl +Bd): no ^C break menu on serial */
    argv[n++] = "--";
    argv[n++] = "-root"; argv[n++] = root;
    argv[n++] = "-bindir"; argv[n++] = bindir;
    argv[n++] = "-progname"; argv[n++] = "erl";
    argv[n++] = "--";
    argv[n++] = "-home"; argv[n++] = "/";
    argv[n++] = "--";
    argv[n++] = "-boot"; argv[n++] = boot;
    argv[n++] = "-boot_var"; argv[n++] = "RELEASE_LIB"; argv[n++] = libdir;
    argv[n++] = "-mode"; argv[n++] = "embedded";
    argv[n++] = "-config"; argv[n++] = sysconfig;
    argv[n++] = "-noshell";
    if (iex) {
        argv[n++] = "-user"; argv[n++] = "elixir";
        argv[n++] = "-extra"; argv[n++] = "--no-halt"; argv[n++] = "+iex";
    } else {
        argv[n++] = "-s"; argv[n++] = "elixir"; argv[n++] = "start_cli";
        argv[n++] = "-extra"; argv[n++] = "--no-halt";
    }
    argv[n] = NULL;

    logmsg("exec %s (%s mode)", beam, iex ? "iex" : "app");

    /* exec keeps us PID 1. ERTS reaps its own erl_child_setup. */
    execv(beam, (char *const *)argv);
    logmsg("execv %s: %s", beam, strerror(errno));
    sleep(5);
    reboot(RB_POWER_OFF);
    return 1;
}
