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
- **Package manager:** [MacPorts](https://www.macports.org)
- **FUSE:** OSXFUSE 2.7.5
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

**MacPorts**

Download the `.pkg` for your macOS version from https://www.macports.org/install.php, then update the ports tree:

```bash
sudo port selfupdate
```

**OSXFUSE**

On macOS 10.7 (Lion), you can install OSXFUSE 2.7.5 using MacPorts:

```bash
sudo port install osxfuse @2.7.5
```

Then load the kernel extension:

```bash
sudo kextload /Library/Extensions/osxfusefs.kext
```


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

`_FILE_OFFSET_BITS=64` is required to support files larger than 2 GB. The source now defines it by default, but keeping the compile flag is still recommended for clarity.

> **Note:** libsmb2 is linked as a static archive (`/usr/local/lib/libsmb2.a`) rather than via `-lsmb2`. On this toolchain the dynamic library does not export all symbols, so the static archive must be specified directly.

> **Important (OSXFUSE linkage):** If both `/opt/local` and `/usr/local` OSXFUSE libraries are installed, link `smb2fs` against `/usr/local/lib/libosxfuse.2.dylib`. Linking against `/opt/local/lib/libosxfuse.2.dylib` can cause mount handoff failure with:
> `This program is not meant to be called directly. The OSXFUSE library calls it.`
>
> Verify the binary with:
> ```bash
> otool -L ./smb2fs | egrep -i 'osxfuse|fuse'
> ```
> Expected:
> `... /usr/local/lib/libosxfuse.2.dylib ...`

---

## Usage

Create a mount point and run `smb2fs`:

```bash
mkdir ~/mnt
./smb2fs ~/mnt -o server=192.168.1.1,share=MyShare,user=alice,domain=MYDOMAIN
```

For better security, avoid passing `password=...` on the command line. Prefer one of:

```bash
# Interactive prompt (no password in argv/history)
./smb2fs ~/mnt -o server=192.168.1.1,share=MyShare,user=alice,password_prompt,domain=MYDOMAIN

# File descriptor (example uses stdin as fd 0)
printf '%s' 'secret' | ./smb2fs ~/mnt -o server=192.168.1.1,share=MyShare,user=alice,passfd=0,domain=MYDOMAIN
```

You can also use `~/.nsmbrc` (`DOMAIN:USERNAME:PASSWORD`) if preferred.

| Option     | Required | Description                          |
|------------|----------|--------------------------------------|
| `server`   | yes      | IP address or hostname of the server |
| `share`    | yes      | Name of the SMB share                |
| `user`     | yes      | Username                             |
| `password` | no       | Password (avoid command line if possible) |
| `passfd`   | no       | Read password from file descriptor     |
| `password_prompt` | no | Read password via interactive prompt |
| `domain`   | no       | Windows/AD domain name               |

Use only one password source at a time: `password`, `passfd`, or `password_prompt`.

To unmount:

```bash
umount ~/mnt
```

> **Do not run `smb2fs` with `sudo`.** OSXFUSE 2.7 requires the mount process to run as the user who owns the FUSE device. Running as root will fail with "Operation not permitted".

---

## Known limitations

- **Single-threaded:** libsmb2 is not thread-safe. `smb2fs` passes `-s` to FUSE to enforce single-threaded operation.
- **Static permissions:** All directories are hardcoded to `0755` and files to `0644`, owned by the user who ran the mount. Actual SMB permissions are not reflected.
- **No SMB1:** Only SMB2 and above are supported.
- **Limited testing:** Only tested on macOS 10.7 Lion with OSXFUSE 2.7.5 and libsmb2 built from source.

---

## Credits

Uses [libsmb2](https://github.com/sahlberg/libsmb2) by **Ronnie Sahlberg**, licensed under LGPL-2.1. The included submodule is a fork with modifications specific to this project.

---

## License

smb2fuse is MIT licensed — see [LICENSE](LICENSE).
libsmb2 (submodule) is LGPL-2.1 — see the headers in `libsmb2/`.
