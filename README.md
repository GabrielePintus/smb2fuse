# smb2fuse

A FUSE-based filesystem for macOS that allows you to mount SMB2/CIFS network shares as local directories using [libsmb2](https://github.com/sahlberg/libsmb2).

> **Note:** This is a personal project. It works for my use case and is provided as-is, without warranty. Not affiliated with or endorsed by Apple Inc.

---

## What it does

`smb2fuse` enables you to mount an SMB2 share on macOS as if it were a native local folder. Once mounted, the share is accessible via Finder, the Terminal, or any standard application for browsing, reading, writing, creating, deleting, and renaming files.

**Supported operations:** `read`, `write`, `create`, `truncate`, `unlink`, `mkdir`, `rmdir`, `rename`, `readdir`, `statfs`.

---

## Why smb2fuse?

Many industrial or creative environments rely on legacy hardware (e.g., CNC machines, laboratory equipment, or specialized scanners) that requires older operating systems like macOS 10.7 (Lion) to run proprietary drivers or software.

Modern security standards have deprecated **SMBv1** due to critical vulnerabilities. However, older versions of macOS often struggle with native SMB2/3 implementations or Active Directory ACLs. This creates a dilemma: leave the network vulnerable by enabling SMBv1, or lose access to network shares.

`smb2fuse` bridges this gap by:
* **Ensuring Security:** Allowing legacy systems to connect via SMB2/3, keeping SMBv1 disabled on your servers.
* **Modern Compatibility:** Leveraging `libsmb2` to provide better support for modern Active Directory environments and network shares than the native Lion filesystem client.
* **Seamless Integration:** Mounting shares as local FUSE directories so legacy apps can interact with network data as if it were on a local disk.

---

## My setup

This is the environment I used. Other configurations may work, but this is what I tested.

- **OS:** macOS 10.7 (Lion)
- **Dev tools:** Xcode + Command Line Tools
- **FUSE:** FUSE for macOS 3.11.2 from the official archive
- **Library:** libsmb2 (included as a git submodule)

---

## Installation

### 1. Clone the repository

Make sure to include submodules:

```bash
git clone --recurse-submodules https://github.com/GabrielePintus/smb2fuse.git
cd smb2fuse
```

### 2. Install prerequisites

**Xcode & Command Line Tools**

On older macOS versions the App Store may not offer a compatible Xcode version. Download the `.dmg` directly from https://developer.apple.com/download/all/?q=Xcode after having signed in with your Apple ID. Once downloaded, install Xcode, then install the command line tools either from Xcode's Preferences > Downloads or download the `.dmg` for your macOS version from https://developer.apple.com/download/all/?q=Command%20Line%20Tools.

**FUSE for macOS**

Download the legacy FUSE package directly from the official archive:

https://macfuse.github.io/archive.html

Then load the kernel extension:

```bash
sudo /Library/Filesystems/osxfuse.fs/Contents/Resources/load_osxfuse
```

If you are installing or upgrading FUSE on an existing Lion machine, a reboot before the first mount attempt is strongly recommended.


### 3. Build libsmb2

Compile and install the bundled library.

#### 3a. Find your macOS SDK path

The build needs the macOS SDK to locate the `CommonCrypto` headers used for SMB3 AES encryption. Find the path on your machine:

```bash
find /Applications/Xcode.app -name "CommonCrypto.h" 2>/dev/null
```

The path will look like:
```
/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.8.sdk/usr/include/CommonCrypto/CommonCrypto.h
```

Take the portion up to and including `usr/include` — that is your `SDK_INCLUDE` path.

#### 3b. Bootstrap and configure

```bash
cd libsmb2
chmod +x bootstrap
./bootstrap
./configure --prefix=/usr/local \
    --without-libkrb5 \
    CFLAGS="-O2 -idirafter <SDK_INCLUDE> -D_FILE_OFFSET_BITS=64"
```

Replace `<SDK_INCLUDE>` with the path found above, for example:
```
-idirafter /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX10.8.sdk/usr/include
```

**Why these flags:**
- `--without-libkrb5`: disables Kerberos/GSSAPI support. This project uses NTLM authentication only, and the macOS GSS framework headers are not compatible with this GCC version.
- `-O2`: enables stable compiler optimizations on GCC 4.2.1; this guide intentionally avoids `-O3` on the legacy toolchain.
- `-idirafter <SDK_INCLUDE>`: makes `CommonCrypto/CommonCrypto.h` (needed for AES) findable without overriding system headers. Using `-I` instead causes conflicts with GCC built-ins in the SDK's `ctype.h`.

#### 3c. Build and install

```bash
make
sudo make install
cd ..
```

### 4. Build smb2fuse

```bash
make
```

`_FILE_OFFSET_BITS=64` is required to support files larger than 2 GB. The source now defines it by default, but keeping the compile flag is still recommended for clarity.

The root `Makefile` uses the same flags shown below and defaults to `PREFIX=/usr/local`. If needed, you can override it:

```bash
make PREFIX=/usr/local
```

Equivalent build command:

```bash
gcc -o smb2fs smb2fs.c \
    -I/usr/local/include/osxfuse/fuse \
    -I/usr/local/include/osxfuse \
    -I/usr/local/include \
    /usr/local/lib/libsmb2.a \
    /usr/local/lib/libosxfuse.2.dylib \
    -Wl,-rpath,/usr/local/lib \
    -O2 \
    -D_FILE_OFFSET_BITS=64
```

> **Note:** libsmb2 is linked as a static archive (`/usr/local/lib/libsmb2.a`) rather than via `-lsmb2`. On this toolchain the dynamic library does not export all symbols, so the static archive must be specified directly.

> **Important (FUSE linkage):** `smb2fs` expects the official FUSE install under `/usr/local` and should link against `/usr/local/lib/libosxfuse.2.dylib`.
>
> Verify the binary with:
> ```bash
> make check-link
> ```
> Expected:
> `... /usr/local/lib/libosxfuse.2.dylib ...`

---

## Usage

Run `smb2fs` with an explicit mount point:

```bash
mkdir ~/mnt
./smb2fs ~/mnt --server 192.168.1.1 --share MyShare --user alice --domain MYDOMAIN
```

If you omit the mount point, `smb2fs` creates one automatically using this fallback order:

1. `/Volumes/<share>`
2. `~/Volumes/<share>`
3. `./<share>`

SMB connection parameters now use dedicated CLI options. The old `-o server=...,share=...,user=...` form is no longer supported.

`--user` is optional. If you omit it, `smb2fs` attempts guest/anonymous access.

If you set a user but do not pass any password option, `smb2fs` prompts interactively by default.

To list the shares visible on a host for the current credentials:

```bash
./smb2fs --list-shares --server 192.168.1.1 --user alice --domain MYDOMAIN
```

For better security, avoid passing `--password ...` on the command line. `--password` remains available as a convenience option, but it can leak into shell history and briefly into process arguments. If you omit all password options and a user is set, `smb2fs` uses the interactive prompt automatically. You can also choose one of these explicitly:

```bash
# Interactive prompt (no password in argv/history)
./smb2fs ~/mnt --server 192.168.1.1 --share MyShare --user alice --password-prompt --domain MYDOMAIN

# File descriptor (example uses stdin as fd 0)
printf '%s' 'secret' | ./smb2fs ~/mnt --server 192.168.1.1 --share MyShare --user alice --passfd 0 --domain MYDOMAIN
```

| Option     | Required | Description                          |
|------------|----------|--------------------------------------|
| `--list-shares` | no   | List visible shares on the server and exit |
| `--server`   | yes      | IP address or hostname of the server |
| `--share`    | yes      | Name of the SMB share                |
| `--user`     | no       | Username; omit it to attempt guest/anonymous access |
| `--password` | no       | Convenience option; may leak via shell history and process arguments |
| `--passfd`   | no       | Read password from file descriptor   |
| `--password-prompt` | no | Read password via interactive prompt |
| `--domain`   | no       | Windows/AD domain name; a trailing `.local` is stripped automatically |
| `--volname`  | no       | Finder-visible volume label; defaults to `share` |
| `--help`     | no       | Show built-in help and exit          |

Use only one password source at a time: `--password`, `--passfd`, or `--password-prompt`. If you omit all three and a user is set, the interactive prompt is used automatically. If you omit both user and password options, `smb2fs` attempts guest/anonymous access.

Generic FUSE options are still passed separately, for example `-f`, `-d`, or `-o allow_other`.

`--list-shares` connects to `IPC$`, prints the browseable shares visible to the current credentials, hides the administrative `IPC$` entry, and exits without mounting. Some servers do not allow anonymous enumeration, so guest mode may fail unless you provide `--user`.

To unmount:

```bash
umount ~/mnt
```

> **Do not run `smb2fs` with `sudo`.** On Lion, the FUSE mount process needs to run as the logged-in user who owns the FUSE device. Running as root can fail with "Operation not permitted".

---

## Known limitations

- **Single-threaded:** libsmb2 is not thread-safe. `smb2fs` passes `-s` to FUSE to enforce single-threaded operation.
- **Static permissions:** All directories are hardcoded to `0755` and files to `0644`, owned by the user who ran the mount. Actual SMB permissions are not reflected.
- **No SMB1:** Only SMB2 and above are supported.
- **Limited testing:** Only tested on macOS 10.7 Lion with FUSE for macOS 3.11.2 and libsmb2 built from source.

---

## Credits

Uses [libsmb2](https://github.com/sahlberg/libsmb2) by **Ronnie Sahlberg**, licensed under LGPL-2.1. The included submodule is a fork with modifications specific to this project.

---

## License

smb2fuse is MIT licensed — see [LICENSE](LICENSE).
libsmb2 (submodule) is LGPL-2.1 — see the headers in `libsmb2/`.
