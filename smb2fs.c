/* smb2fs.c - FUSE filesystem for SMB2 shares using libsmb2
 *
 * Usage: smb2fs <mountpoint> -o server=HOST,share=SHARE,user=USER,password=PASS[,domain=DOMAIN]
 *
 * Build on macOS with OSXFUSE:
 *   gcc -o smb2fs smb2fs.c \
 *       -I/opt/local/include/osxfuse/fuse -I/opt/local/include/osxfuse -I/usr/local/include \
 *       -L/usr/local/lib -lsmb2 \
 *       -L/opt/local/lib -losxfuse \
 *       -D_FILE_OFFSET_BITS=64
 */

#define FUSE_USE_VERSION 26

#include <stdint.h>
#include <stddef.h>
#include <sys/statvfs.h>
#include <fuse/fuse.h>
#include <fuse/fuse_opt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>

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
    int nterr = smb2_get_nterror(smb2_ctx);
    if (nterr)
        return -nterror_to_errno((uint32_t)nterr);
    return -EIO;
}

struct smb2fs_config {
    char *server;
    char *share;
    char *user;
    char *password;
    char *domain;
};

static struct smb2fs_config cfg = { NULL, NULL, NULL, NULL, NULL };

#define SMB2FS_OPT(t, p) { t, offsetof(struct smb2fs_config, p), 1 }

static struct fuse_opt smb2fs_opts[] = {
    SMB2FS_OPT("server=%s",   server),
    SMB2FS_OPT("share=%s",    share),
    SMB2FS_OPT("user=%s",     user),
    SMB2FS_OPT("password=%s", password),
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
    if (fuse_path[0] == '/' && fuse_path[1] == '\0')
        return "";
    return fuse_path + 1;
}

static int smb2fs_getattr(const char *path, struct stat *stbuf)
{
    if (strcmp(path, "/") == 0) {
        memset(stbuf, 0, sizeof(*stbuf));
        stbuf->st_mode  = S_IFDIR | 0755;
        stbuf->st_nlink = 2;
        return 0;
    }

    struct smb2_stat_64 st;
    if (smb2_stat(smb2_ctx, smb2path(path), &st) < 0)
        return smb2fs_errno();

    smb2stat_to_stat(&st, stbuf);
    return 0;
}

static int smb2fs_readdir(const char *path, void *buf, fuse_fill_dir_t filler,
                          off_t offset, struct fuse_file_info *fi)
{
    (void)offset; (void)fi;

    struct smb2dir *dir = smb2_opendir(smb2_ctx, smb2path(path));
    if (dir == NULL)
        return smb2fs_errno();

    filler(buf, ".",  NULL, 0);
    filler(buf, "..", NULL, 0);

    struct smb2dirent *ent;
    while ((ent = smb2_readdir(smb2_ctx, dir)) != NULL) {
        struct stat st;
        smb2stat_to_stat(&ent->st, &st);
        filler(buf, ent->name, &st, 0);
    }

    smb2_closedir(smb2_ctx, dir);
    return 0;
}

static int smb2fs_open(const char *path, struct fuse_file_info *fi)
{
    int flags = 0;
    switch (fi->flags & O_ACCMODE) {
        case O_RDONLY: flags = O_RDONLY; break;
        case O_WRONLY: flags = O_WRONLY; break;
        default:       flags = O_RDWR;   break;
    }

    struct smb2fh *fh = smb2_open(smb2_ctx, smb2path(path), flags);
    if (fh == NULL)
        return smb2fs_errno();

    fi->fh = (uint64_t)(uintptr_t)fh;
    return 0;
}

static int smb2fs_create(const char *path, mode_t mode, struct fuse_file_info *fi)
{
    (void)mode;
    struct smb2fh *fh = smb2_open(smb2_ctx, smb2path(path),
                                   O_CREAT | O_WRONLY | O_TRUNC);
    if (fh == NULL)
        return smb2fs_errno();

    fi->fh = (uint64_t)(uintptr_t)fh;
    return 0;
}

static int smb2fs_read(const char *path, char *buf, size_t size, off_t offset,
                       struct fuse_file_info *fi)
{
    (void)path;
    struct smb2fh *fh = (struct smb2fh *)(uintptr_t)fi->fh;

    if (smb2_lseek(smb2_ctx, fh, offset, SEEK_SET, NULL) < 0)
        return smb2fs_errno();

    int ret = smb2_read(smb2_ctx, fh, (uint8_t *)buf, size);
    return (ret < 0) ? smb2fs_errno() : ret;
}

static int smb2fs_write(const char *path, const char *buf, size_t size,
                        off_t offset, struct fuse_file_info *fi)
{
    (void)path;
    struct smb2fh *fh = (struct smb2fh *)(uintptr_t)fi->fh;

    if (smb2_lseek(smb2_ctx, fh, offset, SEEK_SET, NULL) < 0)
        return smb2fs_errno();

    int ret = smb2_write(smb2_ctx, fh, (uint8_t *)buf, size);
    return (ret < 0) ? smb2fs_errno() : ret;
}

static int smb2fs_release(const char *path, struct fuse_file_info *fi)
{
    (void)path;
    struct smb2fh *fh = (struct smb2fh *)(uintptr_t)fi->fh;
    smb2_close(smb2_ctx, fh);
    return 0;
}

static int smb2fs_truncate(const char *path, off_t size)
{
    if (smb2_truncate(smb2_ctx, smb2path(path), (uint64_t)size) < 0)
        return smb2fs_errno();
    return 0;
}

static int smb2fs_unlink(const char *path)
{
    if (smb2_unlink(smb2_ctx, smb2path(path)) < 0)
        return smb2fs_errno();
    return 0;
}

static int smb2fs_mkdir(const char *path, mode_t mode)
{
    (void)mode;
    if (smb2_mkdir(smb2_ctx, smb2path(path)) < 0)
        return smb2fs_errno();
    return 0;
}

static int smb2fs_rmdir(const char *path)
{
    if (smb2_rmdir(smb2_ctx, smb2path(path)) < 0)
        return smb2fs_errno();
    return 0;
}

static int smb2fs_rename(const char *from, const char *to)
{
    if (smb2_rename(smb2_ctx, smb2path(from), smb2path(to)) < 0)
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
    struct fuse_args args = FUSE_ARGS_INIT(argc, argv);

    if (fuse_opt_parse(&args, &cfg, smb2fs_opts, NULL) < 0)
        return 1;

    if (!cfg.server || !cfg.share || !cfg.user) {
        fprintf(stderr,
            "Usage: %s <mountpoint> -o server=HOST,share=SHARE,user=USER,password=PASS[,domain=DOMAIN]\n",
            argv[0]);
        return 1;
    }

    smb2_ctx = smb2_init_context();
    if (!smb2_ctx) {
        fprintf(stderr, "Failed to init smb2 context\n");
        return 1;
    }

    smb2_set_user(smb2_ctx, cfg.user);
    if (cfg.password)
        smb2_set_password(smb2_ctx, cfg.password);
    if (cfg.domain)
        smb2_set_domain(smb2_ctx, cfg.domain);

    if (smb2_connect_share(smb2_ctx, cfg.server, cfg.share, cfg.user) < 0) {
        fprintf(stderr, "Connect failed: %s\n", smb2_get_error(smb2_ctx));
        if (cfg.password) {
            secure_zero(cfg.password, strlen(cfg.password));
            cfg.password = NULL;
        }
        smb2_destroy_context(smb2_ctx);
        return 1;
    }

    /* Authentication complete — clear the plaintext password from memory */
    if (cfg.password) {
        secure_zero(cfg.password, strlen(cfg.password));
        cfg.password = NULL;
    }

    fprintf(stderr, "Connected to //%s/%s, mounting...\n", cfg.server, cfg.share);

    /* -s = single-threaded (libsmb2 is not thread-safe) */
    fuse_opt_add_arg(&args, "-s");
    fuse_opt_add_arg(&args, "-o");
    fuse_opt_add_arg(&args, "defer_permissions");

    int ret = fuse_main(args.argc, args.argv, &smb2fs_ops, NULL);

    smb2_disconnect_share(smb2_ctx);
    smb2_destroy_context(smb2_ctx);
    return ret;
}
