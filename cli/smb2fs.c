/* smb2fs.c - FUSE filesystem for SMB2 shares using libsmb2
 *
 * Usage: smb2fs [mountpoint] --server HOST --share SHARE [--user USER]
 *        [--password PASS|--passfd FD|--password-prompt] [--domain DOMAIN]
 *        [--volname NAME] [FUSE options]
 *        If mountpoint is omitted, smb2fs tries /Volumes/<share>, then ~/Volumes/<share>,
 *        then ./<share>.
 *        If no password source is provided, smb2fs prompts interactively when a user is set;
 *        otherwise it attempts guest/anonymous access.
 *        Prefer --password-prompt or --passfd over --password to avoid argv/history exposure.
 *
 * Build on macOS with the official FUSE for macOS install:
 *   gcc -o smb2fs smb2fs.c \
 *       -I/usr/local/include/osxfuse/fuse -I/usr/local/include/osxfuse -I/usr/local/include \
 *       /usr/local/lib/libsmb2.a \
 *       /usr/local/lib/libosxfuse.2.dylib \
 *       -Wl,-rpath,/usr/local/lib \
 *       -O2 \
 *       -D_FILE_OFFSET_BITS=64
 */

#define FUSE_USE_VERSION 26

#ifndef _FILE_OFFSET_BITS
#define _FILE_OFFSET_BITS 64
#endif

#include <stdint.h>
#include <stddef.h>
#include <sys/statvfs.h>
#include <fuse/fuse.h>
#include <fuse/fuse_opt.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <fcntl.h>
#include <poll.h>
#include <sys/stat.h>
#include <unistd.h>

#include <smb2/smb2.h>
#include <smb2/libsmb2.h>
#include <smb2/libsmb2-raw.h>
#include <smb2/smb2-errors.h>

#ifndef ENOTSUP
#define ENOTSUP EOPNOTSUPP
#endif

#define SMB2FS_DEFAULT_IOSIZE "8388608"
#define SMB2FS_MAX_ASYNC_WRITES 32
#define SMB2FS_MAX_ASYNC_WRITE_SIZE (1024 * 1024)

static struct smb2_context *smb2_ctx = NULL;
static struct fuse_operations smb2fs_ops;
static int smb2fs_perf_log = 0;
static FILE *smb2fs_perf_stream = NULL;

/* Securely zero memory without compiler elision. */
static void secure_zero(void *ptr, size_t len)
{
    volatile unsigned char *p = (volatile unsigned char *)ptr;
    while (len--) *p++ = 0;
}

/* Map the last libsmb2 NT error to a POSIX errno value. */
static int smb2fs_errno(void)
{
    int err;
    int nterr;
    if (!smb2_ctx)
        return -EIO;

    nterr = smb2_get_nterror(smb2_ctx);
    if (!nterr)
        return -EIO;

    err = nterror_to_errno((uint32_t)nterr);
    if (err > 0)
        return -err;
    return -EIO;
}

static int smb2fs_result(int rc)
{
    return (rc < 0) ? rc : 0;
}

static int smb2fs_perf_init(void)
{
    const char *perf = getenv("SMB2FS_PERF");

    smb2fs_perf_log = 0;
    smb2fs_perf_stream = NULL;

    if (!perf || *perf == '\0' || strcmp(perf, "0") == 0)
        return 0;

    smb2fs_perf_log = 1;
    if (strcmp(perf, "1") == 0) {
        smb2fs_perf_stream = stderr;
        return 0;
    }

    smb2fs_perf_stream = fopen(perf, "a");
    if (!smb2fs_perf_stream) {
        fprintf(stderr, "Warning: could not open SMB2FS_PERF log '%s': %s\n",
                perf, strerror(errno));
        smb2fs_perf_stream = stderr;
        return -1;
    }

    setvbuf(smb2fs_perf_stream, NULL, _IOLBF, 0);
    return 0;
}

static void smb2fs_perf_close(void)
{
    if (smb2fs_perf_stream && smb2fs_perf_stream != stderr)
        fclose(smb2fs_perf_stream);
    smb2fs_perf_stream = NULL;
    smb2fs_perf_log = 0;
}

static void smb2fs_perf_printf(const char *fmt, ...)
{
    va_list ap;

    if (!smb2fs_perf_log || !smb2fs_perf_stream)
        return;

    va_start(ap, fmt);
    vfprintf(smb2fs_perf_stream, fmt, ap);
    va_end(ap);
    fflush(smb2fs_perf_stream);
}

struct smb2fs_config {
    char *server;
    char *share;
    char *user;
    char *password;
    char *domain;
    char *volname;
    int   passfd;
    int   password_prompt;
    int   list_shares;
};

static struct smb2fs_config cfg = { NULL, NULL, NULL, NULL, NULL, NULL, -1, 0, 0 };

struct smb2fs_handle {
    struct smb2fh *fh;
    int open_flags;
    char *path;
    uint64_t write_bytes;
    uint64_t write_calls;
    uint64_t write_submits;
    size_t max_write_request;
    int max_write_in_flight;
};

static void smb2fs_secure_free(char **ptr, size_t len)
{
    if (!ptr || !*ptr)
        return;
    if (len > 0)
        secure_zero(*ptr, len);
    free(*ptr);
    *ptr = NULL;
}

static void smb2fs_free_config(void)
{
    free(cfg.server);
    cfg.server = NULL;
    free(cfg.share);
    cfg.share = NULL;
    free(cfg.user);
    cfg.user = NULL;
    if (cfg.password) {
        secure_zero(cfg.password, strlen(cfg.password));
        free(cfg.password);
        cfg.password = NULL;
    }
    free(cfg.domain);
    cfg.domain = NULL;
    free(cfg.volname);
    cfg.volname = NULL;
    cfg.passfd = -1;
    cfg.password_prompt = 0;
    cfg.list_shares = 0;
}

static int smb2fs_set_string(char **dst, const char *value)
{
    char *copy;

    if (!dst || !value)
        return -1;

    copy = strdup(value);
    if (!copy)
        return -1;

    free(*dst);
    *dst = copy;
    return 0;
}

static int smb2fs_parse_int(const char *value, int *out)
{
    char *end;
    long parsed;

    if (!value || !out)
        return -1;

    errno = 0;
    parsed = strtol(value, &end, 10);
    if (errno != 0 || !end || *end != '\0' ||
        parsed < INT_MIN || parsed > INT_MAX) {
        return -1;
    }

    *out = (int)parsed;
    return 0;
}

static int smb2fs_strip_local_domain_suffix(char *domain)
{
    static const char suffix[] = ".local";
    size_t domain_len;
    size_t suffix_len = sizeof(suffix) - 1;
    size_t i;

    if (!domain)
        return 0;

    domain_len = strlen(domain);
    if (domain_len <= suffix_len)
        return 0;

    for (i = 0; i < suffix_len; i++) {
        unsigned char ch = (unsigned char)domain[domain_len - suffix_len + i];
        if (tolower(ch) != (unsigned char)suffix[i])
            return 0;
    }

    domain[domain_len - suffix_len] = '\0';
    return 1;
}

static void smb2fs_print_usage(FILE *stream, const char *progname)
{
    fprintf(stream,
        "Usage:\n"
        "  %s --list-shares --server HOST [--user USER]\n"
        "     [--password PASS | --passfd FD | --password-prompt]\n"
        "     [--domain DOMAIN]\n"
        "\n"
        "  %s [mountpoint] --server HOST --share SHARE [--user USER]\n"
        "     [--password PASS | --passfd FD | --password-prompt]\n"
        "     [--domain DOMAIN] [--volname NAME] [FUSE options]\n"
        "\n"
        "Options:\n"
        "  --list-shares           List shares visible on the server and exit\n"
        "  --server HOST           SMB server hostname or IP address\n"
        "  --share SHARE           SMB share name\n"
        "  --user USER             SMB username (optional; omitted means guest/anonymous attempt)\n"
        "  --password PASS         Convenience option; prefer safer methods\n"
        "  --passfd FD             Read password from file descriptor FD\n"
        "  --password-prompt       Prompt interactively for the password\n"
        "  --domain DOMAIN         Windows/AD domain name\n"
        "  --volname NAME          Finder-visible volume label (defaults to share)\n"
        "  -h, --help              Show this help message and exit\n"
        "\n"
        "Notes:\n"
        "  If a user is set and no password source is provided, smb2fs prompts interactively.\n"
        "  If no user and no password source are provided, smb2fs attempts guest/anonymous access.\n"
        "  Prefer --password-prompt or --passfd over --password to avoid argv/history exposure.\n"
        "  Mountpoint is optional; if omitted, smb2fs auto-creates one from the share name.\n",
        progname, progname);
}

static int smb2fs_copy_passthrough_arg(struct fuse_args *raw_args,
                                       const char *arg)
{
    if (!raw_args || !arg)
        return -1;

    if (fuse_opt_add_arg(raw_args, arg) < 0) {
        return -1;
    }

    return 0;
}

static int smb2fs_consume_value_arg(int argc, char *argv[], int *index,
                                    const char *inline_value,
                                    const char **value_out)
{
    if (!index || !value_out)
        return -1;

    if (inline_value) {
        *value_out = inline_value;
        return 0;
    }

    if ((*index + 1) >= argc)
        return -1;

    (*index)++;
    *value_out = argv[*index];
    return 0;
}

static char *smb2fs_next_opt_token(char *tok, char **next_out);

static int smb2fs_is_legacy_smb_option_token(const char *opt)
{
    if (!opt)
        return 0;

    return (strncmp(opt, "server=", 7) == 0) ||
           (strncmp(opt, "share=", 6) == 0) ||
           (strncmp(opt, "user=", 5) == 0) ||
           (strncmp(opt, "password=", 9) == 0) ||
           (strncmp(opt, "domain=", 7) == 0) ||
           (strncmp(opt, "passfd=", 7) == 0) ||
           (strncmp(opt, "volname=", 8) == 0) ||
           (strcmp(opt, "password_prompt") == 0);
}

static int smb2fs_optlist_has_legacy_smb_token(const char *optlist)
{
    char *in;
    char *tok;
    char *next;
    int found = 0;

    if (!optlist)
        return 0;

    in = strdup(optlist);
    if (!in)
        return 0;

    tok = in;
    while (tok && *tok) {
        tok = smb2fs_next_opt_token(tok, &next);
        if (*tok != '\0' && smb2fs_is_legacy_smb_option_token(tok)) {
            found = 1;
            break;
        }
        tok = next;
    }

    free(in);
    return found;
}

static int smb2fs_parse_cli_args(int argc, char *argv[],
                                 struct fuse_args *raw_args,
                                 int *help_out)
{
    int i;
    int stop_parsing = 0;

    if (!raw_args || !help_out || argc < 1 || !argv || !argv[0])
        return -1;

    *help_out = 0;

    if (fuse_opt_add_arg(raw_args, argv[0]) < 0) {
        return -1;
    }

    for (i = 1; i < argc; i++) {
        const char *arg = argv[i];
        const char *value = NULL;

        if (!arg)
            continue;

        if (stop_parsing) {
            if (smb2fs_copy_passthrough_arg(raw_args, arg) < 0)
                return -1;
            continue;
        }

        if (strcmp(arg, "--") == 0) {
            stop_parsing = 1;
            if (smb2fs_copy_passthrough_arg(raw_args, arg) < 0)
                return -1;
            continue;
        }

        if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
            *help_out = 1;
            continue;
        }

        if (strcmp(arg, "--list-shares") == 0) {
            cfg.list_shares = 1;
            continue;
        }

        if (strncmp(arg, "--server", 8) == 0 &&
            (arg[8] == '\0' || arg[8] == '=')) {
            if (smb2fs_consume_value_arg(argc, argv, &i,
                                         (arg[8] == '=') ? arg + 9 : NULL,
                                         &value) < 0 ||
                smb2fs_set_string(&cfg.server, value) < 0) {
                return -1;
            }
            continue;
        }

        if (strncmp(arg, "--share", 7) == 0 &&
            (arg[7] == '\0' || arg[7] == '=')) {
            if (smb2fs_consume_value_arg(argc, argv, &i,
                                         (arg[7] == '=') ? arg + 8 : NULL,
                                         &value) < 0 ||
                smb2fs_set_string(&cfg.share, value) < 0) {
                return -1;
            }
            continue;
        }

        if (strncmp(arg, "--user", 6) == 0 &&
            (arg[6] == '\0' || arg[6] == '=')) {
            if (smb2fs_consume_value_arg(argc, argv, &i,
                                         (arg[6] == '=') ? arg + 7 : NULL,
                                         &value) < 0 ||
                smb2fs_set_string(&cfg.user, value) < 0) {
                return -1;
            }
            continue;
        }

        if (strncmp(arg, "--password", 10) == 0 &&
            (arg[10] == '\0' || arg[10] == '=')) {
            if (smb2fs_consume_value_arg(argc, argv, &i,
                                         (arg[10] == '=') ? arg + 11 : NULL,
                                         &value) < 0 ||
                smb2fs_set_string(&cfg.password, value) < 0) {
                return -1;
            }
            continue;
        }

        if (strncmp(arg, "--passfd", 8) == 0 &&
            (arg[8] == '\0' || arg[8] == '=')) {
            int fd;
            if (smb2fs_consume_value_arg(argc, argv, &i,
                                         (arg[8] == '=') ? arg + 9 : NULL,
                                         &value) < 0 ||
                smb2fs_parse_int(value, &fd) < 0) {
                return -1;
            }
            cfg.passfd = fd;
            continue;
        }

        if (strcmp(arg, "--password-prompt") == 0) {
            cfg.password_prompt = 1;
            continue;
        }

        if (strncmp(arg, "--domain", 8) == 0 &&
            (arg[8] == '\0' || arg[8] == '=')) {
            if (smb2fs_consume_value_arg(argc, argv, &i,
                                         (arg[8] == '=') ? arg + 9 : NULL,
                                         &value) < 0 ||
                smb2fs_set_string(&cfg.domain, value) < 0) {
                return -1;
            }
            continue;
        }

        if (strncmp(arg, "--volname", 9) == 0 &&
            (arg[9] == '\0' || arg[9] == '=')) {
            if (smb2fs_consume_value_arg(argc, argv, &i,
                                         (arg[9] == '=') ? arg + 10 : NULL,
                                         &value) < 0 ||
                smb2fs_set_string(&cfg.volname, value) < 0) {
                return -1;
            }
            continue;
        }

        if (smb2fs_is_legacy_smb_option_token(arg))
            return -1;

        if (strcmp(arg, "-o") == 0 && (i + 1) < argc) {
            if (smb2fs_optlist_has_legacy_smb_token(argv[i + 1]))
                return -1;
            if (smb2fs_copy_passthrough_arg(raw_args, arg) < 0 ||
                smb2fs_copy_passthrough_arg(raw_args, argv[++i]) < 0) {
                return -1;
            }
            continue;
        }

        if (arg[0] == '-' && arg[1] == 'o' && arg[2] != '\0' &&
            smb2fs_optlist_has_legacy_smb_token(arg + 2)) {
            return -1;
        }

        if (smb2fs_copy_passthrough_arg(raw_args, arg) < 0)
            return -1;
    }

    return 0;
}

static char *smb2fs_join_path(const char *base, const char *leaf)
{
    size_t base_len;
    size_t leaf_len;
    int need_slash;
    char *path;

    if (!base || !leaf)
        return NULL;

    base_len = strlen(base);
    leaf_len = strlen(leaf);
    need_slash = (base_len > 0 && base[base_len - 1] != '/');

    path = malloc(base_len + need_slash + leaf_len + 1);
    if (!path)
        return NULL;

    memcpy(path, base, base_len);
    if (need_slash)
        path[base_len++] = '/';
    memcpy(path + base_len, leaf, leaf_len + 1);
    return path;
}

static char *smb2fs_join_unc_path(const char *server, const char *share)
{
    size_t server_len;
    size_t share_len;
    char *path;

    if (!server || !share)
        return NULL;

    server_len = strlen(server);
    share_len = strlen(share);
    path = malloc(2 + server_len + 1 + share_len + 1);
    if (!path)
        return NULL;

    path[0] = '/';
    path[1] = '/';
    memcpy(path + 2, server, server_len);
    path[2 + server_len] = '/';
    memcpy(path + 2 + server_len + 1, share, share_len + 1);
    return path;
}

static int smb2fs_prepare_directory(const char *path, int *created_out)
{
    struct stat st;

    if (!path)
        return -1;

    if (created_out)
        *created_out = 0;

    if (mkdir(path, 0755) == 0) {
        if (created_out)
            *created_out = 1;
        return 0;
    }

    if (errno != EEXIST)
        return -1;

    if (stat(path, &st) < 0)
        return -1;

    if (!S_ISDIR(st.st_mode)) {
        errno = ENOTDIR;
        return -1;
    }

    return 0;
}

static int smb2fs_should_try_next_mountpoint(int err)
{
    switch (err) {
    case EACCES:
    case EPERM:
    case EROFS:
    case ENOTDIR:
    case ENOENT:
    case ELOOP:
        return 1;
    default:
        return 0;
    }
}

static int smb2fs_prepare_auto_mountpoint(const char *share,
                                          char **mountpoint_out,
                                          int *mountpoint_created_out,
                                          char **parent_out,
                                          int *parent_created_out)
{
    char *path = NULL;
    char *home_volumes = NULL;
    const char *home;
    int err;

    if (!share || !mountpoint_out || !mountpoint_created_out ||
        !parent_out || !parent_created_out) {
        errno = EINVAL;
        return -1;
    }

    *mountpoint_out = NULL;
    *mountpoint_created_out = 0;
    *parent_out = NULL;
    *parent_created_out = 0;

    path = smb2fs_join_path("/Volumes", share);
    if (!path) {
        errno = ENOMEM;
        return -1;
    }
    if (smb2fs_prepare_directory(path, mountpoint_created_out) == 0) {
        *mountpoint_out = path;
        return 0;
    }
    err = errno;
    free(path);
    path = NULL;
    if (!smb2fs_should_try_next_mountpoint(err)) {
        errno = err;
        return -1;
    }

    home = getenv("HOME");
    if (home && home[0] != '\0') {
        home_volumes = smb2fs_join_path(home, "Volumes");
        if (!home_volumes) {
            errno = ENOMEM;
            return -1;
        }
        if (smb2fs_prepare_directory(home_volumes, parent_created_out) == 0) {
            path = smb2fs_join_path(home_volumes, share);
            if (!path) {
                if (*parent_created_out)
                    (void)rmdir(home_volumes);
                free(home_volumes);
                errno = ENOMEM;
                return -1;
            }
            if (smb2fs_prepare_directory(path, mountpoint_created_out) == 0) {
                *mountpoint_out = path;
                *parent_out = home_volumes;
                return 0;
            }
            err = errno;
            free(path);
            path = NULL;
            if (*parent_created_out)
                (void)rmdir(home_volumes);
            free(home_volumes);
            home_volumes = NULL;
            *parent_created_out = 0;
            if (!smb2fs_should_try_next_mountpoint(err)) {
                errno = err;
                return -1;
            }
        } else {
            err = errno;
            free(home_volumes);
            home_volumes = NULL;
            if (!smb2fs_should_try_next_mountpoint(err)) {
                errno = err;
                return -1;
            }
        }
    }

    path = strdup(share);
    if (!path) {
        errno = ENOMEM;
        return -1;
    }
    if (smb2fs_prepare_directory(path, mountpoint_created_out) == 0) {
        *mountpoint_out = path;
        return 0;
    }

    err = errno;
    free(path);
    errno = err;
    return -1;
}

static void smb2fs_cleanup_auto_mountpoint(char **mountpoint,
                                           int *mountpoint_created,
                                           char **parent,
                                           int *parent_created)
{
    if (mountpoint && *mountpoint) {
        if (mountpoint_created && *mountpoint_created)
            (void)rmdir(*mountpoint);
        free(*mountpoint);
        *mountpoint = NULL;
    }
    if (parent && *parent) {
        if (parent_created && *parent_created)
            (void)rmdir(*parent);
        free(*parent);
        *parent = NULL;
    }
    if (mountpoint_created)
        *mountpoint_created = 0;
    if (parent_created)
        *parent_created = 0;
}

static int smb2fs_password_from_fd(int fd, char **password_out)
{
    char chunk[256];
    char *buf = NULL;
    char *tmp;
    size_t len = 0;
    size_t cap = 0;
    size_t newcap;
    ssize_t nread;

    if (!password_out || fd < 0)
        return -1;

    while ((nread = read(fd, chunk, sizeof(chunk))) > 0) {
        if (len + (size_t)nread > 65536) {
            secure_zero(chunk, sizeof(chunk));
            smb2fs_secure_free(&buf, len);
            return -1;
        }
        if (len + (size_t)nread + 1 > cap) {
            newcap = cap ? cap : 256;
            while (newcap < len + (size_t)nread + 1)
                newcap *= 2;
            tmp = realloc(buf, newcap);
            if (!tmp) {
                smb2fs_secure_free(&buf, len);
                secure_zero(chunk, sizeof(chunk));
                return -1;
            }
            buf = tmp;
            cap = newcap;
        }
        memcpy(buf + len, chunk, (size_t)nread);
        len += (size_t)nread;
    }

    secure_zero(chunk, sizeof(chunk));

    if (nread < 0) {
        smb2fs_secure_free(&buf, len);
        return -1;
    }

    if (!buf) {
        buf = calloc(1, 1);
        if (!buf)
            return -1;
    } else {
        buf[len] = '\0';
    }

    while (len > 0 && (buf[len - 1] == '\n' || buf[len - 1] == '\r'))
        buf[--len] = '\0';

    *password_out = buf;
    return 0;
}

static int smb2fs_password_from_prompt(char **password_out)
{
    char *pw;
    char *copy;
    size_t len;

    if (!password_out)
        return -1;

    pw = getpass("SMB password: ");
    if (!pw)
        return -1;

    len = strlen(pw);
    copy = malloc(len + 1);
    if (!copy) {
        if (len)
            secure_zero(pw, len);
        return -1;
    }

    memcpy(copy, pw, len + 1);
    if (len)
        secure_zero(pw, len);
    *password_out = copy;
    return 0;
}

/* Overwrite password=... segments in an argv-style vector to reduce exposure. */
static void smb2fs_scrub_password_vector(int argc, char *argv[])
{
    int i;

    for (i = 0; i < argc; i++) {
        char *arg = argv[i];
        char *p;

        if (!arg)
            continue;

        p = strstr(arg, "password=");
        while (p) {
            p += strlen("password=");
            while (*p && *p != ',')
                *p++ = 'x';
            p = strstr(p, "password=");
        }
    }
}

static void smb2fs_scrub_password_fuse_args(struct fuse_args *args)
{
    if (!args)
        return;
    smb2fs_scrub_password_vector(args->argc, args->argv);
}

static char *smb2fs_next_opt_token(char *tok, char **next_out)
{
    char *p;

    if (!next_out)
        return tok;

    *next_out = NULL;
    if (!tok)
        return NULL;

    for (p = tok; *p != '\0'; p++) {
        if (*p == '\\' && p[1] != '\0') {
            p++;
            continue;
        }
        if (*p == ',') {
            *p = '\0';
            *next_out = p + 1;
            break;
        }
    }

    return tok;
}

/*
 * Return 1 if a mountpoint (positional, non-option argument) is present in
 * the arg list, 0 otherwise.  Skips argv[0] and the value token after -o.
 */
static int smb2fs_has_mountpoint(const struct fuse_args *args)
{
    int i;
    for (i = 1; i < args->argc; i++) {
        const char *arg = args->argv[i];
        if (!arg)
            continue;
        if (arg[0] == '-') {
            if (arg[1] == 'o' && arg[2] == '\0')
                i++; /* skip the option-list value that follows */
            continue;
        }
        return 1; /* positional argument found = mountpoint */
    }
    return 0;
}

static int smb2fs_add_generated_mount_opt(struct fuse_args *dst, const char *opt)
{
    char *optlist = NULL;

    if (!dst || !opt)
        return -1;

    if (fuse_opt_add_opt_escaped(&optlist, opt) < 0) {
        free(optlist);
        return -1;
    }

    if (!optlist)
        return -1;

    if (fuse_opt_add_arg(dst, "-o") < 0 ||
        fuse_opt_add_arg(dst, optlist) < 0) {
        free(optlist);
        return -1;
    }

    free(optlist);
    return 0;
}

static int smb2fs_add_generated_keyval_opt(struct fuse_args *dst,
                                           const char *key,
                                           const char *value)
{
    char *opt;
    size_t key_len;
    size_t value_len;
    int rc;

    if (!dst || !key || !value)
        return -1;

    key_len = strlen(key);
    value_len = strlen(value);
    opt = malloc(key_len + 1 + value_len + 1);
    if (!opt)
        return -1;

    memcpy(opt, key, key_len);
    opt[key_len] = '=';
    memcpy(opt + key_len + 1, value, value_len + 1);
    rc = smb2fs_add_generated_mount_opt(dst, opt);
    free(opt);
    return rc;
}

static int smb2fs_access_mode(int flags, int default_mode)
{
    switch (flags & O_ACCMODE) {
    case O_RDONLY:
    case O_WRONLY:
    case O_RDWR:
        return flags & O_ACCMODE;
    default:
        return default_mode;
    }
}

static int smb2fs_supported_open_flags(int fuse_flags, int default_mode,
                                       int creating)
{
    int flags = smb2fs_access_mode(fuse_flags, default_mode);

    if (fuse_flags & O_SYNC)
        flags |= O_SYNC;
    if (fuse_flags & O_TRUNC)
        flags |= O_TRUNC;
    if (creating) {
        flags |= O_CREAT;
        if (fuse_flags & O_EXCL)
            flags |= O_EXCL;
    }

    return flags;
}

static struct smb2fs_handle *smb2fs_handle_from_fi(struct fuse_file_info *fi)
{
    if (!fi || fi->fh == 0)
        return NULL;
    return (struct smb2fs_handle *)(uintptr_t)fi->fh;
}

static int smb2fs_set_handle(struct fuse_file_info *fi,
                             const char *smb_path,
                             struct smb2fh *fh,
                             int open_flags)
{
    struct smb2fs_handle *handle;

    if (!fi || !smb_path || !fh)
        return -EINVAL;

    handle = calloc(1, sizeof(*handle));
    if (!handle)
        goto nomem;

    handle->path = strdup(smb_path);
    if (!handle->path)
        goto nomem;

    handle->fh = fh;
    handle->open_flags = open_flags;
    fi->fh = (uint64_t)(uintptr_t)handle;
    return 0;

nomem:
    /* Keep ownership simple on partial setup failure: close the SMB handle here. */
    free(handle);
    smb2_close(smb2_ctx, fh);
    return -ENOMEM;
}

static int smb2fs_open_handle(const char *smb_path,
                              struct fuse_file_info *fi,
                              int smb_flags)
{
    struct smb2fh *fh;

    if (!smb_path || !fi)
        return -EINVAL;

    fh = smb2_open(smb2_ctx, smb_path, smb_flags);
    if (fh == NULL)
        return smb2fs_errno();

    return smb2fs_set_handle(fi, smb_path, fh, fi->flags);
}

static void smb2fs_close_fi_handle(struct fuse_file_info *fi)
{
    struct smb2fs_handle *handle = smb2fs_handle_from_fi(fi);

    if (!handle)
        return;

    smb2_close(smb2_ctx, handle->fh);
    free(handle->path);
    free(handle);
    fi->fh = 0;
}

static const char *smb2fs_share_type_name(uint32_t type)
{
    switch (type & 0x00000003) {
    case SHARE_TYPE_DISKTREE:
        return "disk";
    case SHARE_TYPE_PRINTQ:
        return "printer";
    case SHARE_TYPE_DEVICE:
        return "device";
    case SHARE_TYPE_IPC:
        return "ipc";
    default:
        return "unknown";
    }
}

static int smb2fs_should_show_share(const struct srvsvc_SHARE_INFO_1 *info)
{
    if (!info)
        return 0;

    return ((info->type & 0x00000003) != SHARE_TYPE_IPC);
}

static int smb2fs_list_shares(void)
{
    struct srvsvc_NetrShareEnum_rep *rep;
    struct srvsvc_SHARE_INFO_1_CONTAINER *container;
    size_t name_width = strlen("Name");
    size_t type_width = strlen("Type");
    uint32_t shown = 0;
    int has_remarks = 0;
    uint32_t i;

    rep = smb2_share_enum_sync(smb2_ctx, SHARE_INFO_1);
    if (!rep) {
        fprintf(stderr, "Share enumeration failed: %s\n", smb2_get_error(smb2_ctx));
        return 1;
    }

    container = &rep->ses.ShareInfo.Level1;
    if (container->EntriesRead > 0 && container->Buffer == NULL) {
        fprintf(stderr, "Share enumeration returned no data buffer.\n");
        smb2_free_data(smb2_ctx, rep);
        return 1;
    }

    for (i = 0; i < container->EntriesRead; i++) {
        const struct srvsvc_SHARE_INFO_1 *info = &container->Buffer->share_info_1[i];
        const char *name = info->netname.utf8 ? info->netname.utf8 : "";
        const char *type = smb2fs_share_type_name(info->type);
        const char *remark = info->remark.utf8 ? info->remark.utf8 : "";
        size_t name_len = strlen(name);
        size_t type_len = strlen(type);

        if (!smb2fs_should_show_share(info))
            continue;

        if (name_len > name_width)
            name_width = name_len;
        if (type_len > type_width)
            type_width = type_len;
        if (remark[0] != '\0')
            has_remarks = 1;
        shown++;
    }

    if (shown == 0) {
        printf("No browseable shares found.\n");
        smb2_free_data(smb2_ctx, rep);
        return 0;
    }

    if (has_remarks) {
        printf("%-*s  %-*s  %s\n",
               (int)name_width, "Name",
               (int)type_width, "Type",
               "Remark");
        printf("%-*s  %-*s  %s\n",
               (int)name_width, "----",
               (int)type_width, "----",
               "------");
    } else {
        printf("%-*s  %s\n", (int)name_width, "Name", "Type");
        printf("%-*s  %s\n", (int)name_width, "----", "----");
    }

    for (i = 0; i < container->EntriesRead; i++) {
        const struct srvsvc_SHARE_INFO_1 *info = &container->Buffer->share_info_1[i];
        const char *name = info->netname.utf8 ? info->netname.utf8 : "";
        const char *type = smb2fs_share_type_name(info->type);
        const char *remark = info->remark.utf8 ? info->remark.utf8 : "";

        if (!smb2fs_should_show_share(info))
            continue;

        if (has_remarks) {
            printf("%-*s  %-*s  %s\n",
                   (int)name_width, name,
                   (int)type_width, type,
                   remark);
        } else {
            printf("%-*s  %s\n",
                   (int)name_width, name,
                   type);
        }
    }

    smb2_free_data(smb2_ctx, rep);
    return 0;
}

static int smb2fs_prepare_mount_args(struct fuse_args *src, struct fuse_args *dst)
{
    int i;

    if (!src || !dst || src->argc < 1 || !src->argv || !src->argv[0])
        return -1;

    if (fuse_opt_add_arg(dst, src->argv[0]) < 0)
        return -1;

    for (i = 1; i < src->argc; i++) {
        const char *arg = src->argv[i];

        if (!arg)
            continue;

        if (fuse_opt_add_arg(dst, arg) < 0)
            return -1;
    }

    /* -s = single-threaded (libsmb2 is not thread-safe) */
    if (fuse_opt_add_arg(dst, "-s") < 0 ||
        fuse_opt_add_arg(dst, "-o") < 0 ||
        fuse_opt_add_arg(dst, "defer_permissions,auto_xattr,iosize=" SMB2FS_DEFAULT_IOSIZE) < 0) {
        return -1;
    }

    /* Append volname= for the Finder-visible volume label */
    {
        const char *vname = cfg.volname ? cfg.volname : cfg.share;

        if (!vname)
            return -1;
        if (smb2fs_add_generated_keyval_opt(dst, "volname", vname) < 0)
            return -1;
    }

    /* Append fsname=//server/share for mount identity */
    {
        char *fsname_value;

        if (!cfg.server || !cfg.share)
            return -1;
        fsname_value = smb2fs_join_unc_path(cfg.server, cfg.share);
        if (!fsname_value)
            return -1;
        if (smb2fs_add_generated_keyval_opt(dst, "fsname", fsname_value) < 0) {
            free(fsname_value);
            return -1;
        }
        free(fsname_value);
    }

    return 0;
}

static int smb2fs_prepare_runtime_args(int argc, char *argv[],
                                       struct fuse_args *raw_args,
                                       int *help_requested,
                                       char **auto_mountpoint,
                                       int *auto_mountpoint_created,
                                       char **auto_mount_parent,
                                       int *auto_mount_parent_created)
{
    if (smb2fs_parse_cli_args(argc, argv, raw_args, help_requested) < 0) {
        fprintf(stderr,
                "Invalid command line. Use --server/--share/--user style options;\n"
                "legacy SMB options inside -o are no longer supported.\n\n");
        smb2fs_print_usage(stderr, argv[0]);
        return -1;
    }

    smb2fs_scrub_password_vector(argc, argv);
    smb2fs_scrub_password_fuse_args(raw_args);

    if (*help_requested)
        return 0;

    if (!cfg.server || (!cfg.list_shares && !cfg.share)) {
        smb2fs_print_usage(stderr, argv[0]);
        return -1;
    }

    /* If no mountpoint was passed, choose the standard fallback chain. */
    if (!cfg.list_shares && !smb2fs_has_mountpoint(raw_args)) {
        if (smb2fs_prepare_auto_mountpoint(cfg.share,
                                           auto_mountpoint,
                                           auto_mountpoint_created,
                                           auto_mount_parent,
                                           auto_mount_parent_created) < 0) {
            fprintf(stderr, "Failed to create automatic mountpoint for '%s': %s\n",
                    cfg.share, strerror(errno));
            return -1;
        }

        fprintf(stderr, "Using '%s' as mountpoint.\n", *auto_mountpoint);
        if (fuse_opt_insert_arg(raw_args, 1, *auto_mountpoint) < 0) {
            fprintf(stderr, "Failed to insert mountpoint into args\n");
            return -1;
        }
    }

    return 0;
}

static int smb2fs_prepare_password(int *password_from_argv_out,
                                   char **runtime_password_out)
{
    int pw_sources = 0;
    int password_from_argv = 0;

    if (!password_from_argv_out || !runtime_password_out)
        return -1;

    if (cfg.password)
        pw_sources++;
    if (cfg.passfd >= 0)
        pw_sources++;
    if (cfg.password_prompt)
        pw_sources++;
    password_from_argv = (cfg.password != NULL);

    if (pw_sources == 0 && cfg.user) {
        cfg.password_prompt = 1;
        pw_sources = 1;
    }

    if (pw_sources > 1) {
        fprintf(stderr,
                "Choose only one password source: --password, --passfd, or --password-prompt\n");
        return -1;
    }

    if (cfg.passfd >= 0) {
        if (smb2fs_password_from_fd(cfg.passfd, runtime_password_out) != 0) {
            fprintf(stderr, "Failed to read password from passfd=%d\n", cfg.passfd);
            return -1;
        }
        cfg.password = *runtime_password_out;
    } else if (cfg.password_prompt) {
        if (smb2fs_password_from_prompt(runtime_password_out) != 0) {
            fprintf(stderr, "Failed to read password from prompt\n");
            return -1;
        }
        cfg.password = *runtime_password_out;
    }

    *password_from_argv_out = password_from_argv;
    return 0;
}

static int smb2fs_create_context(void)
{
    smb2fs_perf_init();

    smb2_ctx = smb2_init_context();
    if (!smb2_ctx) {
        fprintf(stderr, "Failed to init smb2 context\n");
        return -1;
    }
    return 0;
}

static int smb2fs_apply_domain_normalization(void)
{
    char *original_domain;

    if (!cfg.domain)
        return 0;

    original_domain = strdup(cfg.domain);
    if (!original_domain) {
        fprintf(stderr, "Failed to normalize domain name\n");
        return -1;
    }
    if (smb2fs_strip_local_domain_suffix(cfg.domain)) {
        fprintf(stderr,
                "Info: normalized domain '%s' to '%s' for NTLM authentication.\n",
                original_domain, cfg.domain);
    }
    free(original_domain);
    return 0;
}

static void smb2fs_apply_auth_to_context(void)
{
    if (cfg.user)
        smb2_set_user(smb2_ctx, cfg.user);
    if (cfg.password)
        smb2_set_password(smb2_ctx, cfg.password);
    if (cfg.domain)
        smb2_set_domain(smb2_ctx, cfg.domain);
}

static int smb2fs_connect(int *connected_out)
{
    if (!connected_out)
        return -1;

    if (smb2_connect_share(smb2_ctx, cfg.server,
                           cfg.list_shares ? "IPC$" : cfg.share,
                           cfg.user) < 0) {
        fprintf(stderr, "Connect failed: %s\n", smb2_get_error(smb2_ctx));
        return -1;
    }

    *connected_out = 1;
    return 0;
}

static void smb2fs_clear_runtime_password(void)
{
    if (cfg.password)
        smb2fs_secure_free(&cfg.password, strlen(cfg.password));
}

static int smb2fs_run_connected_mode(struct fuse_args *raw_args,
                                     struct fuse_args *mount_args)
{
    int ret;

    if (cfg.list_shares)
        return smb2fs_list_shares();

    fprintf(stderr, "Connected to //%s/%s, mounting...\n", cfg.server, cfg.share);

    if (smb2fs_prepare_mount_args(raw_args, mount_args) < 0) {
        fprintf(stderr, "Failed to prepare FUSE arguments\n");
        return 1;
    }

    ret = fuse_main(mount_args->argc, mount_args->argv, &smb2fs_ops, NULL);

    if (ret == 255) {
        fprintf(stderr,
                "OSXFUSE mount failed after SMB authentication. "
                "The FUSE kernel extension may be missing, unloaded, "
                "or incompatible with the libosxfuse user-space library.\n");
        fprintf(stderr,
                "Check the OSXFUSE install and kext state, then retry.\n");
    }

    return ret;
}

/* Convert smb2_stat_64 to struct stat */
static void smb2stat_to_stat(const struct smb2_stat_64 *s2, struct stat *st)
{
    memset(st, 0, sizeof(*st));
    if (s2->smb2_type == SMB2_TYPE_DIRECTORY) {
        st->st_mode  = S_IFDIR | 0755;
        st->st_nlink = 2;
    } else {
        st->st_mode  = S_IFREG | 0644;
        st->st_nlink = 1;
    }
    st->st_uid   = getuid();
    st->st_gid   = getgid();
    st->st_size  = (off_t)s2->smb2_size;
    st->st_atime = (time_t)s2->smb2_atime;
    st->st_mtime = (time_t)s2->smb2_mtime;
    st->st_ctime = (time_t)s2->smb2_ctime;
}

/* Strip leading '/' to get the SMB2 relative path */
static const char *smb2path(const char *fuse_path)
{
    if (fuse_path == NULL || fuse_path[0] != '/')
        return NULL;
    if (fuse_path[0] == '/' && fuse_path[1] == '\0')
        return "";
    return fuse_path + 1;
}

static uint32_t smb2fs_io_size(size_t size, uint32_t server_limit)
{
    size_t limit = server_limit ? (size_t)server_limit : (64 * 1024);

    if (limit > (size_t)INT_MAX)
        limit = (size_t)INT_MAX;
    if (size < limit)
        limit = size;

    if (limit == 0)
        return 0;
    return (uint32_t)limit;
}

static int smb2fs_io_offset(off_t base, size_t delta, uint64_t *out)
{
    uint64_t ubase;

    if (base < 0 || !out)
        return -EINVAL;

    ubase = (uint64_t)base;
    if (ubase > UINT64_MAX - (uint64_t)delta)
        return -EOVERFLOW;

    *out = ubase + (uint64_t)delta;
    return 0;
}

static int smb2fs_transfer_fits_fuse_result(size_t size)
{
    if (size > (size_t)INT_MAX)
        return -EIO;
    return 0;
}

static void *smb2fs_init(struct fuse_conn_info *conn)
{
    if (!conn)
        return NULL;

    if (conn->capable & FUSE_CAP_BIG_WRITES)
        conn->want |= FUSE_CAP_BIG_WRITES;
    if (conn->capable & FUSE_CAP_ASYNC_READ)
        conn->want |= FUSE_CAP_ASYNC_READ;

    if (conn->max_write > 0 && conn->max_write > (8 * 1024 * 1024))
        conn->max_write = 8 * 1024 * 1024;
    if (conn->max_readahead > 0 && conn->max_readahead > (8 * 1024 * 1024))
        conn->max_readahead = 8 * 1024 * 1024;

    return NULL;
}

struct smb2fs_async_write_state {
    int in_flight;
    int error;
};

struct smb2fs_async_write_req {
    struct smb2fs_async_write_state *state;
    uint32_t expected;
};

static void smb2fs_async_write_cb(struct smb2_context *smb2, int status,
                                  void *command_data, void *cb_data)
{
    struct smb2fs_async_write_req *req = cb_data;
    struct smb2fs_async_write_state *state = req ? req->state : NULL;
    (void)smb2;
    (void)command_data;

    if (!state) {
        free(req);
        return;
    }

    if (status < 0 && state->error == 0) {
        state->error = status;
    } else if ((uint32_t)status != req->expected && state->error == 0) {
        state->error = -EIO;
    }

    if (state->in_flight > 0)
        state->in_flight--;

    free(req);
}

static int smb2fs_service_until_write_slot(struct smb2fs_async_write_state *state,
                                           int max_in_flight)
{
    while (state->error == 0 && state->in_flight >= max_in_flight) {
        struct pollfd pfd;

        memset(&pfd, 0, sizeof(pfd));
        pfd.fd = smb2_get_fd(smb2_ctx);
        if (pfd.fd < 0)
            return -EIO;
        pfd.events = smb2_which_events(smb2_ctx);

        if (poll(&pfd, 1, 1000) < 0) {
            if (errno == EINTR)
                continue;
            return -EIO;
        }
        if (pfd.revents == 0)
            continue;
        if (smb2_service(smb2_ctx, pfd.revents) < 0)
            return smb2fs_errno();
    }

    return state->error;
}

static int smb2fs_drain_async_writes(struct smb2fs_async_write_state *state)
{
    while (state->in_flight > 0) {
        struct pollfd pfd;

        memset(&pfd, 0, sizeof(pfd));
        pfd.fd = smb2_get_fd(smb2_ctx);
        if (pfd.fd < 0)
            return -EIO;
        pfd.events = smb2_which_events(smb2_ctx);

        if (poll(&pfd, 1, 1000) < 0) {
            if (errno == EINTR)
                continue;
            return -EIO;
        }
        if (pfd.revents == 0)
            continue;
        if (smb2_service(smb2_ctx, pfd.revents) < 0)
            return smb2fs_errno();
    }

    return state->error;
}

static int smb2fs_getattr(const char *path, struct stat *stbuf)
{
    const char *smb_path;
    int rc;

    if (strcmp(path, "/") == 0) {
        memset(stbuf, 0, sizeof(*stbuf));
        stbuf->st_mode  = S_IFDIR | 0755;
        stbuf->st_nlink = 2;
        stbuf->st_uid   = getuid();
        stbuf->st_gid   = getgid();
        return 0;
    }

    smb_path = smb2path(path);
    if (!smb_path)
        return -EINVAL;

    struct smb2_stat_64 st;
    rc = smb2_stat(smb2_ctx, smb_path, &st);
    if (rc < 0)
        return rc;

    smb2stat_to_stat(&st, stbuf);
    return 0;
}

static int smb2fs_fgetattr(const char *path, struct stat *stbuf,
                           struct fuse_file_info *fi)
{
    struct smb2fs_handle *handle;
    struct smb2_stat_64 st;
    int rc;

    handle = smb2fs_handle_from_fi(fi);
    if (!handle)
        return smb2fs_getattr(path, stbuf);

    rc = smb2_fstat(smb2_ctx, handle->fh, &st);
    if (rc < 0)
        return rc;

    smb2stat_to_stat(&st, stbuf);
    return 0;
}

static int smb2fs_chmod(const char *path, mode_t mode)
{
    const char *smb_path = smb2path(path);
    (void)mode;

    if (!smb_path)
        return -EINVAL;

    return 0;
}

static int smb2fs_chown(const char *path, uid_t uid, gid_t gid)
{
    const char *smb_path = smb2path(path);
    (void)uid;
    (void)gid;

    if (!smb_path)
        return -EINVAL;

    return 0;
}

static int smb2fs_utimens(const char *path, const struct timespec tv[2])
{
    const char *smb_path = smb2path(path);
    (void)tv;

    if (!smb_path)
        return -EINVAL;

    return 0;
}

static int smb2fs_readdir(const char *path, void *buf, fuse_fill_dir_t filler,
                          off_t offset, struct fuse_file_info *fi)
{
    const char *smb_path = smb2path(path);
    (void)offset; (void)fi;

    if (!smb_path)
        return -EINVAL;

    struct smb2dir *dir = smb2_opendir(smb2_ctx, smb_path);
    if (dir == NULL)
        return smb2fs_errno();

    if (filler(buf, ".", NULL, 0) != 0 || filler(buf, "..", NULL, 0) != 0) {
        smb2_closedir(smb2_ctx, dir);
        return 0;
    }

    struct smb2dirent *ent;
    while ((ent = smb2_readdir(smb2_ctx, dir)) != NULL) {
        struct stat st;
        if (strcmp(ent->name, ".") == 0 || strcmp(ent->name, "..") == 0)
            continue;
        smb2stat_to_stat(&ent->st, &st);
        if (filler(buf, ent->name, &st, 0) != 0)
            break;
    }

    smb2_closedir(smb2_ctx, dir);
    return 0;
}

static int smb2fs_open(const char *path, struct fuse_file_info *fi)
{
    const char *smb_path = smb2path(path);
    int flags;
    int ret;

    if (!smb_path)
        return -EINVAL;

    flags = smb2fs_supported_open_flags(fi->flags, O_RDONLY, 0);
    ret = smb2fs_open_handle(smb_path, fi, flags);

    if (ret < 0 && (flags & O_TRUNC) &&
        ((ret == -EACCES) || (ret == -EPERM))) {
        struct smb2fs_handle *handle;
        int trunc_ret;

        ret = smb2fs_open_handle(smb_path, fi, flags & ~O_TRUNC);
        if (ret == 0) {
            handle = smb2fs_handle_from_fi(fi);
            if (!handle)
                return -EBADF;

            trunc_ret = smb2_ftruncate(smb2_ctx, handle->fh, 0);
            if (trunc_ret == 0)
                return 0;

            smb2fs_close_fi_handle(fi);
            ret = trunc_ret;
        }

        if ((ret == -EACCES) || (ret == -EPERM)) {
            ret = smb2_unlink(smb2_ctx, smb_path);
            if (ret < 0)
                return ret;
            ret = smb2fs_open_handle(smb_path, fi, flags | O_CREAT);
        }
    }

    return ret;
}

static int smb2fs_create(const char *path, mode_t mode, struct fuse_file_info *fi)
{
    const char *smb_path = smb2path(path);
    int flags;

    (void)mode;

    if (!smb_path)
        return -EINVAL;

    if (!fi)
        return -EINVAL;

    flags = smb2fs_supported_open_flags(fi->flags, O_WRONLY, 1);
    return smb2fs_open_handle(smb_path, fi, flags);
}

static int smb2fs_read(const char *path, char *buf, size_t size, off_t offset,
                       struct fuse_file_info *fi)
{
    size_t done = 0;
    uint32_t max_read_size;
    struct smb2fs_handle *handle;
    (void)path;
    if (offset < 0)
        return -EINVAL;
    if (size == 0)
        return 0;
    if (smb2fs_transfer_fits_fuse_result(size) < 0)
        return -EIO;

    handle = smb2fs_handle_from_fi(fi);
    if (!handle)
        return -EBADF;

    max_read_size = smb2_get_max_read_size(smb2_ctx);

    while (done < size) {
        uint32_t io_size = smb2fs_io_size(size - done, max_read_size);
        uint64_t read_offset;
        int ret;

        if (io_size == 0)
            break;

        ret = smb2fs_io_offset(offset, done, &read_offset);
        if (ret < 0)
            return ret;

        ret = smb2_pread(smb2_ctx, handle->fh, (uint8_t *)buf + done,
                         io_size, read_offset);
        if (ret < 0)
            return ret;
        if (ret == 0)
            break;

        done += (size_t)ret;
    }

    return (int)done;
}

static int smb2fs_write(const char *path, const char *buf, size_t size,
                        off_t offset, struct fuse_file_info *fi)
{
    size_t done = 0;
    uint32_t max_write_size;
    struct smb2fs_handle *handle;
    struct smb2_stat_64 st;
    struct smb2fs_async_write_state state;
    uint64_t write_offset;
    int ret = 0;
    (void)path;
    if (size == 0)
        return 0;
    if (smb2fs_transfer_fits_fuse_result(size) < 0)
        return -EIO;

    handle = smb2fs_handle_from_fi(fi);
    if (!handle)
        return -EBADF;

    if (handle->open_flags & O_APPEND) {
        /* Enforce append in user space so writes do not depend on FUSE/kernel quirks. */
        int ret;

        ret = smb2_stat(smb2_ctx, handle->path, &st);
        if (ret < 0)
            return ret;
        write_offset = (uint64_t)st.smb2_size;
    } else {
        if (offset < 0)
            return -EINVAL;
        write_offset = (uint64_t)offset;
    }

    max_write_size = smb2_get_max_write_size(smb2_ctx);
    memset(&state, 0, sizeof(state));
    handle->write_calls++;
    handle->write_bytes += (uint64_t)size;
    if (size > handle->max_write_request)
        handle->max_write_request = size;

    while (done < size) {
        uint32_t io_size = smb2fs_io_size(size - done, max_write_size);
        struct smb2fs_async_write_req *req;

        ret = smb2fs_service_until_write_slot(&state, SMB2FS_MAX_ASYNC_WRITES);
        if (ret < 0)
            break;
        if (io_size == 0)
            break;
        if (io_size > SMB2FS_MAX_ASYNC_WRITE_SIZE)
            io_size = SMB2FS_MAX_ASYNC_WRITE_SIZE;
        if (write_offset > UINT64_MAX - (uint64_t)done) {
            ret = -EOVERFLOW;
            break;
        }

        req = calloc(1, sizeof(*req));
        if (!req) {
            ret = -ENOMEM;
            break;
        }
        req->state = &state;
        req->expected = io_size;

        ret = smb2_pwrite_async(smb2_ctx, handle->fh,
                                (const uint8_t *)buf + done, io_size,
                                write_offset + (uint64_t)done,
                                smb2fs_async_write_cb, req);
        if (ret < 0) {
            free(req);
            break;
        }

        state.in_flight++;
        handle->write_submits++;
        if (state.in_flight > handle->max_write_in_flight)
            handle->max_write_in_flight = state.in_flight;
        done += (size_t)io_size;
    }

    if (state.in_flight > 0) {
        int drain_ret = smb2fs_drain_async_writes(&state);
        if (ret == 0 && drain_ret < 0)
            ret = drain_ret;
    }
    if (ret < 0)
        return ret;

    return (int)done;
}

static int smb2fs_flush(const char *path, struct fuse_file_info *fi)
{
    (void)path;
    (void)fi;

    return 0;
}

static int smb2fs_fsync(const char *path, int datasync,
                        struct fuse_file_info *fi)
{
    struct smb2fs_handle *handle;
    (void)path;
    (void)datasync;

    handle = smb2fs_handle_from_fi(fi);
    if (!handle)
        return -EBADF;

    return smb2fs_result(smb2_fsync(smb2_ctx, handle->fh));
}

static int smb2fs_setxattr(const char *path, const char *name,
                           const char *value, size_t size, int flags,
                           uint32_t position)
{
    (void)path;
    (void)name;
    (void)value;
    (void)size;
    (void)flags;
    (void)position;

    return -ENOTSUP;
}

static int smb2fs_getxattr(const char *path, const char *name,
                           char *value, size_t size, uint32_t position)
{
    (void)path;
    (void)name;
    (void)value;
    (void)size;
    (void)position;

    return -ENOTSUP;
}

static int smb2fs_listxattr(const char *path, char *list, size_t size)
{
    (void)path;
    (void)list;
    (void)size;

    return -ENOTSUP;
}

static int smb2fs_removexattr(const char *path, const char *name)
{
    (void)path;
    (void)name;

    return -ENOTSUP;
}

static int smb2fs_release(const char *path, struct fuse_file_info *fi)
{
    struct smb2fs_handle *handle;
    int ret;

    (void)path;
    handle = smb2fs_handle_from_fi(fi);
    if (!handle)
        return -EBADF;

    if (smb2fs_perf_log && handle->write_calls > 0) {
        smb2fs_perf_printf(
            "smb2fs perf: %s write_bytes=%llu write_calls=%llu "
            "max_fuse_write=%zu smb_submits=%llu max_in_flight=%d\n",
            handle->path ? handle->path : path,
            (unsigned long long)handle->write_bytes,
            (unsigned long long)handle->write_calls,
            handle->max_write_request,
            (unsigned long long)handle->write_submits,
            handle->max_write_in_flight);
    }

    ret = smb2_close(smb2_ctx, handle->fh);
    free(handle->path);
    free(handle);
    fi->fh = 0;
    return smb2fs_result(ret);
}

static int smb2fs_truncate(const char *path, off_t size)
{
    const char *smb_path = smb2path(path);
    if (!smb_path || size < 0)
        return -EINVAL;

    return smb2fs_result(smb2_truncate(smb2_ctx, smb_path, (uint64_t)size));
}

static int smb2fs_ftruncate(const char *path, off_t size,
                            struct fuse_file_info *fi)
{
    struct smb2fs_handle *handle;

    if (size < 0)
        return -EINVAL;

    handle = smb2fs_handle_from_fi(fi);
    if (!handle)
        return smb2fs_truncate(path, size);

    return smb2fs_result(smb2_ftruncate(smb2_ctx, handle->fh, (uint64_t)size));
}

static int smb2fs_unlink(const char *path)
{
    const char *smb_path = smb2path(path);
    if (!smb_path)
        return -EINVAL;

    return smb2fs_result(smb2_unlink(smb2_ctx, smb_path));
}

static int smb2fs_mkdir(const char *path, mode_t mode)
{
    const char *smb_path = smb2path(path);
    (void)mode;
    if (!smb_path)
        return -EINVAL;

    return smb2fs_result(smb2_mkdir(smb2_ctx, smb_path));
}

static int smb2fs_rmdir(const char *path)
{
    const char *smb_path = smb2path(path);
    if (!smb_path)
        return -EINVAL;

    return smb2fs_result(smb2_rmdir(smb2_ctx, smb_path));
}

static int smb2fs_rename(const char *from, const char *to)
{
    const char *smb_from = smb2path(from);
    const char *smb_to = smb2path(to);
    if (!smb_from || !smb_to)
        return -EINVAL;

    return smb2fs_result(smb2_rename(smb2_ctx, smb_from, smb_to));
}

static int smb2fs_statfs(const char *path, struct statvfs *stv)
{
    (void)path;
    struct smb2_statvfs s2stv;
    int rc = smb2_statvfs(smb2_ctx, "", &s2stv);
    if (rc < 0)
        return rc;

    memset(stv, 0, sizeof(*stv));
    stv->f_bsize   = s2stv.f_bsize;
    stv->f_frsize  = s2stv.f_frsize;
    stv->f_blocks  = s2stv.f_blocks;
    stv->f_bfree   = s2stv.f_bfree;
    stv->f_bavail  = s2stv.f_bavail;
    stv->f_namemax = s2stv.f_namemax;
    return 0;
}

static struct fuse_operations smb2fs_ops = {
    .init     = smb2fs_init,
    .getattr  = smb2fs_getattr,
    .readdir  = smb2fs_readdir,
    .chmod    = smb2fs_chmod,
    .chown    = smb2fs_chown,
    .utimens  = smb2fs_utimens,
    .open     = smb2fs_open,
    .create   = smb2fs_create,
    .read     = smb2fs_read,
    .write    = smb2fs_write,
    .flush    = smb2fs_flush,
    .fsync    = smb2fs_fsync,
    .setxattr = smb2fs_setxattr,
    .getxattr = smb2fs_getxattr,
    .listxattr = smb2fs_listxattr,
    .removexattr = smb2fs_removexattr,
    .release  = smb2fs_release,
    .truncate = smb2fs_truncate,
    .ftruncate = smb2fs_ftruncate,
    .fgetattr  = smb2fs_fgetattr,
    .unlink   = smb2fs_unlink,
    .mkdir    = smb2fs_mkdir,
    .rmdir    = smb2fs_rmdir,
    .rename   = smb2fs_rename,
    .statfs   = smb2fs_statfs,
};

int main(int argc, char *argv[])
{
    int connected = 0;
    int help_requested = 0;
    int password_from_argv = 0;
    int ret = 1;
    int auto_mountpoint_created = 0;
    int auto_mount_parent_created = 0;
    char *auto_mountpoint = NULL;
    char *auto_mount_parent = NULL;
    char *runtime_password = NULL;
    struct fuse_args raw_args = FUSE_ARGS_INIT(0, NULL);
    struct fuse_args mount_args = FUSE_ARGS_INIT(0, NULL);

    if (smb2fs_prepare_runtime_args(argc, argv, &raw_args, &help_requested,
                                    &auto_mountpoint, &auto_mountpoint_created,
                                    &auto_mount_parent, &auto_mount_parent_created) < 0)
        goto out;

    if (help_requested) {
        smb2fs_print_usage(stdout, argv[0]);
        ret = 0;
        goto out;
    }

    if (smb2fs_prepare_password(&password_from_argv, &runtime_password) < 0)
        goto out;

    if (smb2fs_create_context() < 0)
        goto out;

    if (smb2fs_apply_domain_normalization() < 0)
        goto out;

    smb2fs_apply_auth_to_context();

    if (password_from_argv) {
        fprintf(stderr,
                "Warning: --password may leak into shell history and briefly into process arguments.\n"
                "Prefer --password-prompt or --passfd.\n");
    }

    if (smb2fs_connect(&connected) < 0)
        goto out;

    /* Authentication complete — clear the plaintext password from memory */
    smb2fs_clear_runtime_password();

    ret = smb2fs_run_connected_mode(&raw_args, &mount_args);

out:
    if (connected && smb2_ctx)
        smb2_disconnect_share(smb2_ctx);
    if (smb2_ctx) {
        smb2_destroy_context(smb2_ctx);
        smb2_ctx = NULL;
    }
    fuse_opt_free_args(&mount_args);
    fuse_opt_free_args(&raw_args);
    smb2fs_cleanup_auto_mountpoint(&auto_mountpoint, &auto_mountpoint_created,
                                   &auto_mount_parent, &auto_mount_parent_created);
    smb2fs_free_config();
    smb2fs_perf_close();
    return ret;
}
