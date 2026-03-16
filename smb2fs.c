/* smb2fs.c - FUSE filesystem for SMB2 shares using libsmb2
 *
 * Usage: smb2fs <mountpoint> -o server=HOST,share=SHARE,user=USER[,password=PASS|passfd=FD|password_prompt][,domain=DOMAIN]
 *
 * Build on macOS with OSXFUSE:
 *   gcc -o smb2fs smb2fs.c \
 *       -I/opt/local/include/osxfuse/fuse -I/opt/local/include/osxfuse -I/usr/local/include \
 *       -L/usr/local/lib -lsmb2 \
 *       -L/opt/local/lib -losxfuse \
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
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <limits.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <smb2/smb2.h>
#include <smb2/libsmb2.h>
#include <smb2/smb2-errors.h>

static struct smb2_context *smb2_ctx = NULL;

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

struct smb2fs_config {
    char *server;
    char *share;
    char *user;
    char *password;
    char *domain;
    int   passfd;
    int   password_prompt;
};

static struct smb2fs_config cfg = { NULL, NULL, NULL, NULL, NULL, -1, 0 };

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
    cfg.passfd = -1;
    cfg.password_prompt = 0;
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
            free(buf);
            return -1;
        }
        if (len + (size_t)nread + 1 > cap) {
            newcap = cap ? cap : 256;
            while (newcap < len + (size_t)nread + 1)
                newcap *= 2;
            tmp = realloc(buf, newcap);
            if (!tmp) {
                if (buf) {
                    secure_zero(buf, len);
                    free(buf);
                }
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
        if (buf) {
            secure_zero(buf, len);
            free(buf);
        }
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

/* Overwrite password=... segments in argv to reduce command-line exposure. */
static void scrub_password_argv(struct fuse_args *args)
{
    int i;

    for (i = 0; i < args->argc; i++) {
        char *arg = args->argv[i];
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

static int smb2fs_is_smb_option_token(const char *opt)
{
    if (!opt)
        return 0;
    return (strncmp(opt, "server=", 7) == 0) ||
           (strncmp(opt, "share=", 6) == 0) ||
           (strncmp(opt, "user=", 5) == 0) ||
           (strncmp(opt, "password=", 9) == 0) ||
           (strncmp(opt, "domain=", 7) == 0) ||
           (strncmp(opt, "passfd=", 7) == 0) ||
           (strcmp(opt, "password_prompt") == 0);
}

/* Remove smb2fs-specific tokens from a comma-separated -o option list. */
static char *smb2fs_filter_mount_optlist(const char *optlist)
{
    char *in;
    char *out;
    char *tok;
    char *next;
    size_t out_len = 0;
    size_t max_len;
    int first = 1;

    if (!optlist)
        return NULL;

    max_len = strlen(optlist) + 1;
    in = strdup(optlist);
    out = malloc(max_len);
    if (!in || !out) {
        free(in);
        free(out);
        return NULL;
    }
    out[0] = '\0';

    tok = in;
    while (tok && *tok) {
        next = strchr(tok, ',');
        if (next) {
            *next = '\0';
            next++;
        }

        if (*tok != '\0' && !smb2fs_is_smb_option_token(tok)) {
            size_t tok_len = strlen(tok);
            if (!first) {
                out[out_len++] = ',';
            }
            memcpy(out + out_len, tok, tok_len);
            out_len += tok_len;
            out[out_len] = '\0';
            first = 0;
        }
        tok = next;
    }

    free(in);
    if (out_len == 0) {
        free(out);
        return NULL;
    }
    return out;
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

        if (strcmp(arg, "-o") == 0 && (i + 1) < src->argc) {
            char *filtered = smb2fs_filter_mount_optlist(src->argv[i + 1]);
            if (filtered) {
                if (fuse_opt_add_arg(dst, "-o") < 0 ||
                    fuse_opt_add_arg(dst, filtered) < 0) {
                    free(filtered);
                    return -1;
                }
                free(filtered);
            }
            i++;
            continue;
        }

        if (arg[0] == '-' && arg[1] == 'o' && arg[2] != '\0') {
            char *filtered = smb2fs_filter_mount_optlist(arg + 2);
            if (filtered) {
                if (fuse_opt_add_arg(dst, "-o") < 0 ||
                    fuse_opt_add_arg(dst, filtered) < 0) {
                    free(filtered);
                    return -1;
                }
                free(filtered);
            }
            continue;
        }

        if (smb2fs_is_smb_option_token(arg))
            continue;

        if (fuse_opt_add_arg(dst, arg) < 0)
            return -1;
    }

    /* -s = single-threaded (libsmb2 is not thread-safe) */
    if (fuse_opt_add_arg(dst, "-s") < 0 ||
        fuse_opt_add_arg(dst, "-o") < 0 ||
        fuse_opt_add_arg(dst, "defer_permissions") < 0) {
        return -1;
    }
    return 0;
}

#define SMB2FS_OPT(t, p) { t, offsetof(struct smb2fs_config, p), 1 }

static struct fuse_opt smb2fs_opts[] = {
    SMB2FS_OPT("server=%s",   server),
    SMB2FS_OPT("share=%s",    share),
    SMB2FS_OPT("user=%s",     user),
    SMB2FS_OPT("password=%s", password),
    SMB2FS_OPT("passfd=%d",   passfd),
    SMB2FS_OPT("password_prompt", password_prompt),
    SMB2FS_OPT("domain=%s",   domain),
    FUSE_OPT_END
};

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

static uint32_t smb2fs_io_size(size_t size)
{
    if (size > (size_t)INT_MAX)
        return (uint32_t)INT_MAX;
    return (uint32_t)size;
}

static int smb2fs_getattr(const char *path, struct stat *stbuf)
{
    const char *smb_path;

    if (strcmp(path, "/") == 0) {
        memset(stbuf, 0, sizeof(*stbuf));
        stbuf->st_mode  = S_IFDIR | 0755;
        stbuf->st_nlink = 2;
        return 0;
    }

    smb_path = smb2path(path);
    if (!smb_path)
        return -EINVAL;

    struct smb2_stat_64 st;
    if (smb2_stat(smb2_ctx, smb_path, &st) < 0)
        return smb2fs_errno();

    smb2stat_to_stat(&st, stbuf);
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
    int flags = 0;

    if (!smb_path)
        return -EINVAL;

    switch (fi->flags & O_ACCMODE) {
        case O_RDONLY: flags = O_RDONLY; break;
        case O_WRONLY: flags = O_WRONLY; break;
        default:       flags = O_RDWR;   break;
    }

    struct smb2fh *fh = smb2_open(smb2_ctx, smb_path, flags);
    if (fh == NULL)
        return smb2fs_errno();

    fi->fh = (uint64_t)(uintptr_t)fh;
    return 0;
}

static int smb2fs_create(const char *path, mode_t mode, struct fuse_file_info *fi)
{
    const char *smb_path = smb2path(path);
    int flags;

    if (!smb_path)
        return -EINVAL;

    flags = fi ? (fi->flags & O_ACCMODE) : O_WRONLY;
    if (flags != O_RDONLY && flags != O_WRONLY && flags != O_RDWR)
        flags = O_WRONLY;
    if ((mode & 0222) == 0)
        flags = O_RDONLY;

    struct smb2fh *fh = smb2_open(smb2_ctx, smb_path,
                                   O_CREAT | O_TRUNC | flags);
    if (fh == NULL)
        return smb2fs_errno();

    fi->fh = (uint64_t)(uintptr_t)fh;
    return 0;
}

static int smb2fs_read(const char *path, char *buf, size_t size, off_t offset,
                       struct fuse_file_info *fi)
{
    uint32_t io_size;
    (void)path;
    if (offset < 0)
        return -EINVAL;
    if (size == 0)
        return 0;
    if (!fi || fi->fh == 0)
        return -EBADF;

    struct smb2fh *fh = (struct smb2fh *)(uintptr_t)fi->fh;
    io_size = smb2fs_io_size(size);

    if (smb2_lseek(smb2_ctx, fh, offset, SEEK_SET, NULL) < 0)
        return smb2fs_errno();

    int ret = smb2_read(smb2_ctx, fh, (uint8_t *)buf, io_size);
    return (ret < 0) ? smb2fs_errno() : ret;
}

static int smb2fs_write(const char *path, const char *buf, size_t size,
                        off_t offset, struct fuse_file_info *fi)
{
    uint32_t io_size;
    (void)path;
    if (offset < 0)
        return -EINVAL;
    if (size == 0)
        return 0;
    if (!fi || fi->fh == 0)
        return -EBADF;

    struct smb2fh *fh = (struct smb2fh *)(uintptr_t)fi->fh;
    io_size = smb2fs_io_size(size);

    if (smb2_lseek(smb2_ctx, fh, offset, SEEK_SET, NULL) < 0)
        return smb2fs_errno();

    int ret = smb2_write(smb2_ctx, fh, (const uint8_t *)buf, io_size);
    return (ret < 0) ? smb2fs_errno() : ret;
}

static int smb2fs_release(const char *path, struct fuse_file_info *fi)
{
    (void)path;
    if (!fi || fi->fh == 0)
        return -EBADF;

    struct smb2fh *fh = (struct smb2fh *)(uintptr_t)fi->fh;
    int ret = smb2_close(smb2_ctx, fh);
    fi->fh = 0;
    return (ret < 0) ? smb2fs_errno() : 0;
}

static int smb2fs_truncate(const char *path, off_t size)
{
    const char *smb_path = smb2path(path);
    if (!smb_path || size < 0)
        return -EINVAL;

    if (smb2_truncate(smb2_ctx, smb_path, (uint64_t)size) < 0)
        return smb2fs_errno();
    return 0;
}

static int smb2fs_unlink(const char *path)
{
    const char *smb_path = smb2path(path);
    if (!smb_path)
        return -EINVAL;

    if (smb2_unlink(smb2_ctx, smb_path) < 0)
        return smb2fs_errno();
    return 0;
}

static int smb2fs_mkdir(const char *path, mode_t mode)
{
    const char *smb_path = smb2path(path);
    (void)mode;
    if (!smb_path)
        return -EINVAL;

    if (smb2_mkdir(smb2_ctx, smb_path) < 0)
        return smb2fs_errno();
    return 0;
}

static int smb2fs_rmdir(const char *path)
{
    const char *smb_path = smb2path(path);
    if (!smb_path)
        return -EINVAL;

    if (smb2_rmdir(smb2_ctx, smb_path) < 0)
        return smb2fs_errno();
    return 0;
}

static int smb2fs_rename(const char *from, const char *to)
{
    const char *smb_from = smb2path(from);
    const char *smb_to = smb2path(to);
    if (!smb_from || !smb_to)
        return -EINVAL;

    if (smb2_rename(smb2_ctx, smb_from, smb_to) < 0)
        return smb2fs_errno();
    return 0;
}

static int smb2fs_statfs(const char *path, struct statvfs *stv)
{
    (void)path;
    struct smb2_statvfs s2stv;
    if (smb2_statvfs(smb2_ctx, "", &s2stv) < 0)
        return smb2fs_errno();

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
    .getattr  = smb2fs_getattr,
    .readdir  = smb2fs_readdir,
    .open     = smb2fs_open,
    .create   = smb2fs_create,
    .read     = smb2fs_read,
    .write    = smb2fs_write,
    .release  = smb2fs_release,
    .truncate = smb2fs_truncate,
    .unlink   = smb2fs_unlink,
    .mkdir    = smb2fs_mkdir,
    .rmdir    = smb2fs_rmdir,
    .rename   = smb2fs_rename,
    .statfs   = smb2fs_statfs,
};

int main(int argc, char *argv[])
{
    int connected = 0;
    int pw_sources = 0;
    char *runtime_password = NULL;
    struct fuse_args raw_args = FUSE_ARGS_INIT(argc, argv);
    struct fuse_args args = FUSE_ARGS_INIT(argc, argv);
    struct fuse_args mount_args = FUSE_ARGS_INIT(0, NULL);

    if (fuse_opt_parse(&args, &cfg, smb2fs_opts, NULL) < 0)
    {
        fuse_opt_free_args(&args);
        smb2fs_free_config();
        return 1;
    }
    scrub_password_argv(&args);
    scrub_password_argv(&raw_args);

    if (!cfg.server || !cfg.share || !cfg.user) {
        fprintf(stderr,
            "Usage: %s <mountpoint> -o server=HOST,share=SHARE,user=USER[,password=PASS|passfd=FD|password_prompt][,domain=DOMAIN]\n",
            argv[0]);
        fuse_opt_free_args(&args);
        smb2fs_free_config();
        return 1;
    }

    if (cfg.password)
        pw_sources++;
    if (cfg.passfd >= 0)
        pw_sources++;
    if (cfg.password_prompt)
        pw_sources++;
    if (pw_sources > 1) {
        fprintf(stderr,
            "Choose only one password source: password=, passfd=, or password_prompt\n");
        fuse_opt_free_args(&args);
        smb2fs_free_config();
        return 1;
    }
    if (cfg.passfd >= 0) {
        if (smb2fs_password_from_fd(cfg.passfd, &runtime_password) != 0) {
            fprintf(stderr, "Failed to read password from passfd=%d\n", cfg.passfd);
            fuse_opt_free_args(&args);
            smb2fs_free_config();
            return 1;
        }
        cfg.password = runtime_password;
    } else if (cfg.password_prompt) {
        if (smb2fs_password_from_prompt(&runtime_password) != 0) {
            fprintf(stderr, "Failed to read password from prompt\n");
            fuse_opt_free_args(&args);
            smb2fs_free_config();
            return 1;
        }
        cfg.password = runtime_password;
    }

    smb2_ctx = smb2_init_context();
    if (!smb2_ctx) {
        fprintf(stderr, "Failed to init smb2 context\n");
        fuse_opt_free_args(&args);
        smb2fs_free_config();
        return 1;
    }

    smb2_set_user(smb2_ctx, cfg.user);
    if (cfg.password)
        smb2_set_password(smb2_ctx, cfg.password);
    if (cfg.domain)
        smb2_set_domain(smb2_ctx, cfg.domain);

    if (smb2_connect_share(smb2_ctx, cfg.server, cfg.share, cfg.user) < 0) {
        fprintf(stderr, "Connect failed: %s\n", smb2_get_error(smb2_ctx));
        smb2_destroy_context(smb2_ctx);
        smb2_ctx = NULL;
        fuse_opt_free_args(&args);
        smb2fs_free_config();
        return 1;
    }
    connected = 1;

    /* Authentication complete — clear the plaintext password from memory */
    if (cfg.password) {
        secure_zero(cfg.password, strlen(cfg.password));
        free(cfg.password);
        cfg.password = NULL;
    }

    fprintf(stderr, "Connected to //%s/%s, mounting...\n", cfg.server, cfg.share);

    if (smb2fs_prepare_mount_args(&raw_args, &mount_args) < 0) {
        if (connected)
            smb2_disconnect_share(smb2_ctx);
        smb2_destroy_context(smb2_ctx);
        smb2_ctx = NULL;
        fuse_opt_free_args(&mount_args);
        fuse_opt_free_args(&args);
        smb2fs_free_config();
        return 1;
    }

    int ret = fuse_main(mount_args.argc, mount_args.argv, &smb2fs_ops, NULL);

    if (connected)
        smb2_disconnect_share(smb2_ctx);
    smb2_destroy_context(smb2_ctx);
    smb2_ctx = NULL;
    fuse_opt_free_args(&mount_args);
    fuse_opt_free_args(&args);
    smb2fs_free_config();
    return ret;
}
