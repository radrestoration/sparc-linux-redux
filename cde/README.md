# CDE for the Ultra 10

The Common Desktop Environment (2.5.3, from https://github.com/cdesktopenv/cde) is not in Debian, so it is built here for sparc64 and packaged.
Everything is scripted and runs on the PC as a normal user (no sudo): a sparc64 Debian sid chroot under qemu-user, the same way as
`tools/build-debian.sh`. Requirements are the same (debootstrap, qemu-user-binfmt with the F flag, an /etc/subuid range), plus
`binutils-sparc64-linux-gnu` for stripping.

```
cde/chroot.sh create    # once: the build chroot in /var/tmp (about an hour)
cde/build.sh            # fetch the pinned source, patch, configure, build (about 3 hours the first time; a re-run takes about a minute)
cde/stage.sh            # make install into a staging tree, strip, pack: build/cde/cde-sparc64.tar.gz
cde/package.sh          # build/cde/deb/cde-desktop_*.deb and cde-help_*.deb
tools/build-debian.sh --with-cde
```

`build/cde` is shared with the chroot as `/work`. `CDE_DIR=name` uses `build/name` and a separate chroot instead (clean-build tests).

What had to be worked around (all in the scripts or in `patches/`):

- GCC 16 defaults to C23, where `foo()` means `foo(void)`: the build uses `-std=gnu17`.
- The bundled ksh93 uses `nullptr` as a variable name, a keyword in C23: `patches/0001-ksh93-nullptr-is-a-C23-keyword.patch`.
- The documentation is UTF-8 and the help compiler rejects it in the C locale: the build runs with `LC_ALL=C.UTF-8`.
- A parallel make can compile the `DtMmdb` lexers before bison has produced their headers: `build.sh` makes that directory serially first.
- `configure` needs `--with-tcl=/usr/lib/sparc64-linux-gnu/tcl8.6`, `onsgmls` (package opensp), `liblmdb`, and `libcrypt` before it runs.

The packages install under `/usr/dt`. `dtlogin` gets an LSB init script from the CDE source (`/etc/init.d/dtlogin`), enabled by
`build-debian.sh --with-cde`; `xdm` is not installed.
