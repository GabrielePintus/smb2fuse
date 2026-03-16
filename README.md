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

Compile and install the bundled library. For more detailed information, please refer to the instructions in the original [libsmb2 repository](https://github.com/sahlberg/libsmb2).

```bash
cd libsmb2
./bootstrap
./configure --prefix=/usr/local
make
sudo make install
```

### 4. Build smb2fuse

```bash
gcc -o smb2fs smb2fs.c \
    -I/opt/local/include/osxfuse/fuse \
    -I/opt/local/include/osxfuse \
    -I/usr/local/include \
    -L/usr/local/lib -lsmb2 \
    -L/opt/local/lib -losxfuse \
    -D_FILE_OFFSET_BITS=64
```

The `-D_FILE_OFFSET_BITS=64` flag is required to support files larger than 2 GB. If you installed libsmb2 via MacPorts, adjust the `-I` and `-L` paths to `/opt/local/include` and `/opt/local/lib`.

---

## Usage

Create a mount point and run `smb2fs`:

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
