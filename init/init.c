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
#include <stdint.h>
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
#include <linux/if_packet.h>
#include <linux/if_ether.h>
#include <netinet/ip.h>
#include <netinet/udp.h>
#include <poll.h>

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
    char buf[1024];
    size_t kl = strlen(key);
    const char *p = cmdline;
    while (*p) {
        while (*p == ' ') p++;
        /* token ends at the next space outside double quotes */
        const char *end = p; int q = 0;
        while (*end && (q || *end != ' ')) { if (*end == '"') q = !q; end++; }
        if ((size_t)(end - p) > kl && !memcmp(p, key, kl) && p[kl] == '=') {
            const char *v = p + kl + 1; size_t vl = end - v;
            if (vl >= 2 && v[0] == '"' && v[vl - 1] == '"') { v++; vl -= 2; }
            if (vl >= sizeof buf) vl = sizeof buf - 1;
            memcpy(buf, v, vl);
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


/* ---- minimal DHCPv4 client -------------------------------------------------
 * DISCOVER/OFFER/REQUEST/ACK over a raw AF_PACKET socket (the interface has
 * no address yet, so a normal UDP socket cannot send). Options understood:
 * subnet mask, router, DNS, server id, message type. No renewal: EC2 and QEMU
 * never revoke an address during the life of the instance.
 */
struct dhcp_lease { in_addr_t ip, mask, gw, dns; };

struct dhcp_msg {
    uint8_t op, htype, hlen, hops; uint32_t xid; uint16_t secs, flags;
    uint32_t ciaddr, yiaddr, siaddr, giaddr; uint8_t chaddr[16];
    uint8_t sname[64], file[128]; uint32_t magic; uint8_t opts[312];
} __attribute__((packed));

static uint16_t csum16(const void *data, size_t len) {
    const uint8_t *p = data; uint32_t sum = 0;
    for (; len > 1; len -= 2, p += 2) sum += (p[0] << 8) | p[1];
    if (len) sum += p[0] << 8;
    while (sum >> 16) sum = (sum & 0xffff) + (sum >> 16);
    return htons((uint16_t)~sum);
}

static int dhcp_send(int s, int ifindex, const uint8_t *mac, uint32_t xid, int type,
                     in_addr_t req_ip, in_addr_t server) {
    struct { struct iphdr ip; struct udphdr udp; struct dhcp_msg d; } __attribute__((packed)) pkt;
    memset(&pkt, 0, sizeof pkt);
    struct dhcp_msg *d = &pkt.d;
    d->op = 1; d->htype = 1; d->hlen = 6; d->xid = xid; d->flags = htons(0x8000);
    memcpy(d->chaddr, mac, 6); d->magic = htonl(0x63825363);
    uint8_t *o = d->opts;
    *o++ = 53; *o++ = 1; *o++ = (uint8_t)type;
    if (type == 3) {
        *o++ = 50; *o++ = 4; memcpy(o, &req_ip, 4); o += 4;
        *o++ = 54; *o++ = 4; memcpy(o, &server, 4); o += 4;
    }
    *o++ = 55; *o++ = 3; *o++ = 1; *o++ = 3; *o++ = 6;   /* parameter request: mask, router, dns */
    *o++ = 255;
    size_t dlen = (size_t)(o - (uint8_t *)d);
    if (dlen < 300) dlen = 300;                          /* BOOTP minimum */
    size_t ulen = sizeof pkt.udp + dlen, tlen = sizeof pkt.ip + ulen;
    pkt.udp.source = htons(68); pkt.udp.dest = htons(67); pkt.udp.len = htons((uint16_t)ulen); pkt.udp.check = 0;
    pkt.ip.version = 4; pkt.ip.ihl = 5; pkt.ip.tot_len = htons((uint16_t)tlen); pkt.ip.ttl = 64;
    pkt.ip.protocol = IPPROTO_UDP; pkt.ip.daddr = 0xffffffff; pkt.ip.check = csum16(&pkt.ip, sizeof pkt.ip);
    struct sockaddr_ll to; memset(&to, 0, sizeof to);
    to.sll_family = AF_PACKET; to.sll_protocol = htons(ETH_P_IP); to.sll_ifindex = ifindex;
    to.sll_halen = 6; memset(to.sll_addr, 0xff, 6);
    return sendto(s, &pkt, tlen, 0, (struct sockaddr *)&to, sizeof to) < 0 ? -1 : 0;
}

/* wait up to `ms` for a DHCP message of type `want` with our xid; fill lease */
static int dhcp_recv(int s, uint32_t xid, int want, struct dhcp_lease *l, in_addr_t *server, int ms) {
    for (;;) {
        struct pollfd pf = { s, POLLIN, 0 };
        if (poll(&pf, 1, ms) <= 0) return -1;
        uint8_t buf[1500];
        ssize_t n = recv(s, buf, sizeof buf, 0);
        if (n < (ssize_t)(sizeof(struct iphdr) + sizeof(struct udphdr) + 240)) continue;
        struct iphdr *ip = (struct iphdr *)buf;
        if (ip->protocol != IPPROTO_UDP) continue;
        struct udphdr *udp = (struct udphdr *)(buf + ip->ihl * 4);
        if (ntohs(udp->dest) != 68) continue;
        struct dhcp_msg *d = (struct dhcp_msg *)((uint8_t *)udp + sizeof *udp);
        if (d->op != 2 || d->xid != xid || ntohl(d->magic) != 0x63825363) continue;
        int type = 0; in_addr_t srv = 0; struct dhcp_lease got = { d->yiaddr, 0, 0, 0 };
        uint8_t *o = d->opts, *end = buf + n;
        while (o < end && *o != 255) {
            if (*o == 0) { o++; continue; }
            uint8_t code = o[0], len = o[1]; uint8_t *v = o + 2;
            if (v + len > end) break;
            if (code == 53 && len >= 1) type = v[0];
            if (code == 1 && len >= 4) memcpy(&got.mask, v, 4);
            if (code == 3 && len >= 4) memcpy(&got.gw, v, 4);
            if (code == 6 && len >= 4) memcpy(&got.dns, v, 4);
            if (code == 54 && len >= 4) memcpy(&srv, v, 4);
            o = v + len;
        }
        if (type != want) continue;
        *l = got; if (server) *server = srv ? srv : ip->saddr;
        return 0;
    }
}

static int dhcp_client(int ctl, const char *eth, struct dhcp_lease *lease) {
    struct ifreq ifr; memset(&ifr, 0, sizeof ifr); strncpy(ifr.ifr_name, eth, IFNAMSIZ - 1);
    if (ioctl(ctl, SIOCGIFINDEX, &ifr) < 0) { logmsg("dhcp: SIOCGIFINDEX: %s", strerror(errno)); return -1; }
    int ifindex = ifr.ifr_ifindex;
    if (ioctl(ctl, SIOCGIFHWADDR, &ifr) < 0) { logmsg("dhcp: SIOCGIFHWADDR: %s", strerror(errno)); return -1; }
    uint8_t mac[6]; memcpy(mac, ifr.ifr_hwaddr.sa_data, 6);
    if (if_set_flags(ctl, eth, IFF_UP) < 0) { logmsg("dhcp: %s up: %s", eth, strerror(errno)); return -1; }

    int s = socket(AF_PACKET, SOCK_DGRAM, htons(ETH_P_IP));
    if (s < 0) { logmsg("dhcp: AF_PACKET: %s", strerror(errno)); return -1; }
    struct sockaddr_ll sll; memset(&sll, 0, sizeof sll);
    sll.sll_family = AF_PACKET; sll.sll_protocol = htons(ETH_P_IP); sll.sll_ifindex = ifindex;
    if (bind(s, (struct sockaddr *)&sll, sizeof sll) < 0) { logmsg("dhcp: bind: %s", strerror(errno)); close(s); return -1; }

    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    uint32_t xid = (uint32_t)t.tv_nsec ^ ((uint32_t)mac[5] << 24) ^ (uint32_t)mac[4];
    in_addr_t server = 0; int rc = -1;
    for (int attempt = 0, wait = 2000; attempt < 5 && rc < 0; attempt++, wait = wait < 8000 ? wait * 2 : 8000) {
        if (dhcp_send(s, ifindex, mac, xid, 1, 0, 0) < 0) { logmsg("dhcp: send discover: %s", strerror(errno)); break; }
        if (dhcp_recv(s, xid, 2, lease, &server, wait) < 0) { logmsg("dhcp: no offer (attempt %d)", attempt + 1); continue; }
        if (dhcp_send(s, ifindex, mac, xid, 3, lease->ip, server) < 0) break;
        if (dhcp_recv(s, xid, 5, lease, NULL, wait) == 0) rc = 0;
        else logmsg("dhcp: no ack (attempt %d)", attempt + 1);
    }
    close(s);
    return rc;
}

static in_addr_t g_dns;   /* nameserver chosen by setup_net, used by setup_inetrc */

/* Asterinas with `ip=dhcp`: the kernel runs the DHCP client and reports the
 * lease in /proc/net/dhcp as "eth0 10.0.2.15/24 10.0.2.2 dns 10.0.2.3" (or
 * "eth0 pending"). Wait for it; returns 0 and fills the lease when granted,
 * -1 when the file is absent (plain Linux) or no lease arrives in time. */
static int kernel_dhcp(const char *eth, struct dhcp_lease *l, int *prefix) {
    if (access("/proc/net/dhcp", R_OK) < 0) return -1;
    for (int i = 0; i < 300; i++) {           /* 30 s */
        char buf[512] = {0};
        int fd = open("/proc/net/dhcp", O_RDONLY);
        if (fd < 0) return -1;
        ssize_t n = read(fd, buf, sizeof buf - 1); close(fd);
        if (n <= 0) return -1;                  /* not a DHCP-configured kernel */
        char name[IFNAMSIZ], cidr[64], gw[32], dnsw[8], dns1[32] = "";
        int k = sscanf(buf, "%15s %63s %31s %7s %31s", name, cidr, gw, dnsw, dns1);
        if (k >= 3 && strcmp(name, eth) == 0 && strcmp(cidr, "pending") != 0) {
            char *slash = strchr(cidr, '/');
            if (slash) { *slash = 0; *prefix = atoi(slash + 1); }
            struct in_addr a;
            if (inet_pton(AF_INET, cidr, &a) != 1) return -1;
            l->ip = a.s_addr;
            l->mask = *prefix == 0 ? 0 : htonl(~0u << (32 - *prefix));
            l->gw = inet_pton(AF_INET, gw, &a) == 1 ? a.s_addr : 0;
            l->dns = (k >= 5 && inet_pton(AF_INET, dns1, &a) == 1) ? a.s_addr : 0;
            return 0;
        }
        if (i == 0) logmsg("dhcp: waiting for the kernel's lease on %s", eth);
        usleep(100 * 1000);
    }
    logmsg("dhcp: kernel reported no lease within 30 s");
    return -1;
}

static void setup_net(void) {
    int s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s < 0) { logmsg("socket: %s", strerror(errno)); return; }

    if (if_set_addr(s, "lo", SIOCSIFADDR, htonl(INADDR_LOOPBACK)) < 0)
        logmsg("lo addr: %s", strerror(errno));
    if (if_set_flags(s, "lo", IFF_UP | IFF_RUNNING) < 0)
        logmsg("lo up: %s", strerror(errno));

    char eth[IFNAMSIZ] = "eth0";
    if (find_eth(s, eth, sizeof eth) < 0) {
        logmsg("no ethernet interface found; skipping network");
        close(s);
        return;
    }
    const char *ip = param("uniapp.ip");
    const char *gw = param("uniapp.gw");
    const char *dns = param("uniapp.dns");
    struct in_addr a, g; in_addr_t mask; int prefix = 24;
    char ipbuf[64]; const char *how;

    struct dhcp_lease lease; int kernel_configured = 0;
    if (!ip && kernel_dhcp(eth, &lease, &prefix) == 0) {
        how = "kernel dhcp"; kernel_configured = 1;
        a.s_addr = lease.ip; mask = lease.mask; g.s_addr = lease.gw; g_dns = lease.dns;
    } else if (!ip && dhcp_client(s, eth, &lease) == 0) {
        how = "dhcp";
        a.s_addr = lease.ip; mask = lease.mask ? lease.mask : htonl(0xffffff00);
        g.s_addr = lease.gw; g_dns = lease.dns;
        prefix = 32 - __builtin_ctz(ntohl(mask) ? ntohl(mask) : 1);
        if (!ntohl(mask)) prefix = 0;
    } else {
        how = ip ? "static" : "default";
        if (!ip) ip = "10.0.2.15/24";
        if (!gw) gw = "10.0.2.2";
        snprintf(ipbuf, sizeof ipbuf, "%s", ip);
        char *slash = strchr(ipbuf, '/');
        if (slash) { *slash = 0; prefix = atoi(slash + 1); }
        if (inet_pton(AF_INET, ipbuf, &a) != 1) { logmsg("bad ip %s", ipbuf); close(s); return; }
        mask = prefix == 0 ? 0 : htonl(~0u << (32 - prefix));
        if (inet_pton(AF_INET, gw, &g) != 1) g.s_addr = 0;
        g_dns = 0;
    }
    if (dns) { struct in_addr d; if (inet_pton(AF_INET, dns, &d) == 1) g_dns = d.s_addr; }
    if (!g_dns) inet_pton(AF_INET, "10.0.2.3", (struct in_addr *)&g_dns);
    inet_ntop(AF_INET, &a, ipbuf, sizeof ipbuf);

    if (!kernel_configured) {
    if (if_set_addr(s, eth, SIOCSIFADDR, a.s_addr) < 0) logmsg("%s addr: %s", eth, strerror(errno));
    if (if_set_addr(s, eth, SIOCSIFNETMASK, mask) < 0) logmsg("%s netmask: %s", eth, strerror(errno));
    if (if_set_flags(s, eth, IFF_UP | IFF_RUNNING) < 0) logmsg("%s up: %s", eth, strerror(errno));
    }

    if (g.s_addr && !kernel_configured) {
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
    char gwbuf[32], dnsbuf[32];
    inet_ntop(AF_INET, &g, gwbuf, sizeof gwbuf); inet_ntop(AF_INET, &g_dns, dnsbuf, sizeof dnsbuf);
    logmsg("net: %s %s/%d gw %s dns %s (%s)", eth, ipbuf, prefix, gwbuf, dnsbuf, how);
    close(s);
}

static void write_file(const char *path, const char *content) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { logmsg("write %s: %s", path, strerror(errno)); return; }
    write(fd, content, strlen(content));
    close(fd);
}

static void setup_inetrc(void) {
    unsigned char *b = (unsigned char *)&g_dns;
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
    if (!mode) mode = "iex";
    /* uniapp.code=embedded loads every module of the boot script up front (the
       release default); interactive (default here) loads lazily and roughly
       halves RSS. */
    const char *code_mode = param("uniapp.code");
    int embedded = code_mode && !strcmp(code_mode, "embedded");
    int iex = !strcmp(mode, "iex");
    int erl = !strcmp(mode, "erl");          /* debugging: plain Erlang shell, no Elixir CLI */
    const char *eval = param("uniapp.eval"); /* debugging: Erlang expression run at boot */

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
    setenv("RELEASE_MODE", embedded ? "embedded" : "interactive", 1);
    setenv("RELEASE_NODE", RELEASE_NAME, 1);
    setenv("RELEASE_SYS_CONFIG", sysconfig, 1);
    setenv("ERL_CRASH_DUMP", "/dev/null", 1);
    setenv("KERNEL_CMDLINE", cmdline, 1);

    static char beam[256];
    snprintf(beam, sizeof beam, "%s/beam.smp", bindir);

    const char *argv[80];
    int n = 0;
    argv[n++] = beam;
    argv[n++] = "-Bd";                    /* emulator flag (erl +Bd): no ^C break menu on serial */
    /* Extra emulator flags from the command line, e.g. uniapp.emu="-S 1 -Meamin"
       (erl's "+X" flags are spelled "-X" when passed to beam.smp directly). */
    const char *emu = param("uniapp.emu");
    if (emu) {
        char *tok, *dup = strdup(emu);
        for (tok = strtok(dup, " "); tok && n < 40; tok = strtok(NULL, " ")) argv[n++] = tok;
    }
    argv[n++] = "--";
    argv[n++] = "-root"; argv[n++] = root;
    argv[n++] = "-bindir"; argv[n++] = bindir;
    argv[n++] = "-progname"; argv[n++] = "erl";
    argv[n++] = "--";
    argv[n++] = "-home"; argv[n++] = "/";
    argv[n++] = "--";
    argv[n++] = "-boot"; argv[n++] = boot;
    argv[n++] = "-boot_var"; argv[n++] = "RELEASE_LIB"; argv[n++] = libdir;
    argv[n++] = "-mode"; argv[n++] = embedded ? "embedded" : "interactive";
    argv[n++] = "-config"; argv[n++] = sysconfig;
    if (!erl) argv[n++] = "-noshell";
    if (eval) { argv[n++] = "-eval"; argv[n++] = eval; }
    if (iex) {
        argv[n++] = "-user"; argv[n++] = "elixir";
        argv[n++] = "-extra"; argv[n++] = "--no-halt"; argv[n++] = "+iex";
    } else if (erl) {
        /* Erlang shell on the console; nothing Elixir-specific started. */
    } else {
        argv[n++] = "-s"; argv[n++] = "elixir"; argv[n++] = "start_cli";
        argv[n++] = "-extra"; argv[n++] = "--no-halt";
    }
    argv[n] = NULL;

    logmsg("exec %s (%s mode)", beam, mode);

    /* exec keeps us PID 1. ERTS reaps its own erl_child_setup. */
    execv(beam, (char *const *)argv);
    logmsg("execv %s: %s", beam, strerror(errno));
    sleep(5);
    reboot(RB_POWER_OFF);
    return 1;
}
