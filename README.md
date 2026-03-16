# smb2fuse

A FUSE filesystem for macOS that mounts SMB2/CIFS network shares as local directories using [libsmb2](https://github.com/sahlberg/libsmb2).

> **This is not an official Apple product.** It is an independent open-source utility and is not affiliated with or endorsed by Apple Inc.

---

## What it does

`smb2fuse` lets you mount an SMB2 share on macOS as if it were a local folder. Once mounted, you can browse, read, write, create, delete, and rename files and directories through the normal filesystem interface — Finder, Terminal, or any application.

Supported operations: `read`, `write`, `create`, `truncate`, `unlink`, `mkdir`, `rmdir`, `rename`, `readdir`, `statfs`.

---

## Requirements

- macOS 10.7 (Lion) or later — tested on 10.7
- Xcode + Command Line Tools
- [MacPorts](https://www.macports.org)
- OSXFUSE 2.7.x
- libsmb2

---

## Installing prerequisites

### 1. Xcode and Command Line Tools

Install Xcode from the Mac App Store, then install the command line tools:

```bash
xcode-select --install
```

This provides `gcc`/`clang`, `make`, and the necessary system headers.

### 2. MacPorts

Download and run the `.pkg` installer for your macOS version from:

https://www.macports.org/install.php

After installation, update the ports tree:

```bash
sudo port selfupdate
```

### 3. OSXFUSE

On macOS 10.8 and later:

```bash
sudo port install osxfuse
```

On macOS 10.7 (Lion), MacPorts may not carry a compatible version. Download the `.pkg` installer directly from the OSXFUSE releases page:

https://github.com/osxfuse/osxfuse/releases

Install **OSXFUSE 2.7.5** (the last version supporting Lion). After installing, reboot or load the kernel extension:

```bash
sudo kextload /Library/Extensions/osxfusefs.kext
```

### 4. libsmb2

Clone and build from source:

```bash
git clone https://github.com/sahlberg/libsmb2.git
cd libsmb2
./bootstrap
./configure --prefix=/usr/local
make
sudo make install
```

for more details follow the instructions in the repo.


---

## Building

```bash
gcc -o smb2fs smb2fs.c \
    -I/opt/local/include/osxfuse/fuse \
    -I/opt/local/include/osxfuse \
    -I/usr/local/include \
    -L/usr/local/lib -lsmb2 \
    -L/opt/local/lib -losxfuse \
    -D_FILE_OFFSET_BITS=64
```

The `-D_FILE_OFFSET_BITS=64` flag is required for correct handling of files larger than 2 GB.

If libsmb2 was installed via MacPorts instead of `/usr/local`, adjust the `-I` and `-L` paths to `/opt/local/include` and `/opt/local/lib` accordingly.

---

## Usage

Create a mount point, then run `smb2fs`:

```bash
mkdir ~/mnt
./smb2fs ~/mnt -o server=192.168.1.1,share=MyShare,user=alice,password=secret,domain=MYDOMAIN
```

| Option     | Required | Description                          |
|------------|----------|--------------------------------------|
| `server`   | yes      | IP address or hostname of the server |
| `share`    | yes      | Name of the SMB share                |
| `user`     | yes      | Username                             |
| `password` | no       | Password (omit to leave blank)       |
| `domain`   | no       | Windows/AD domain name               |

To unmount:

```bash
umount ~/mnt
```

> **Important:** Do not run `smb2fs` with `sudo`. OSXFUSE 2.7 requires that the process mounting the filesystem runs as the same user who owns the FUSE device. Running as root will cause the mount to fail with "Operation not permitted".

---

## Notes and known limitations

- **Single-threaded:** libsmb2 is not thread-safe. `smb2fs` automatically passes `-s` to FUSE to enforce single-threaded operation.
- **Fixed permissions:** All directories appear as `drwxr-xr-x` (0755) and all files as `-rw-r--r--` (0644). Ownership shows as the user running the mount, not the actual SMB owner. This is a limitation of the current implementation.
- **No SMB1:** Only SMB2 and above is supported (provided by libsmb2).
- **Tested on:** macOS 10.7 Lion with OSXFUSE 2.7.5 and libsmb2 built from source.

---

## License

MIT — see [LICENSE](LICENSE).
