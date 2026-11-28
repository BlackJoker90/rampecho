---
name: image-build
description: Build a flashable rampecho Pi 4 SD-card image in the pgen-build VM (run-in-vm.sh), from a release tag, and upload it to that GitHub release. Use before starting an image build, and before uploading or announcing an image.
---

# Building a flashable image

Releases are OTA packages; an image only for boot/base-system changes or
when the maintainer asks (CLAUDE.md "Git and releases").

Pi 4 images are built in the Parallels VM `pgen-build` by
`tools/image-build/run-in-vm.sh` (background: `tools/BUILD-IMAGE-PI4.md`).
It builds the working tree of `MAC_REPO` (default: the main checkout)
onto the v2.12.1 base in `/root/pgbase`, runs `prove` as root, fscks the
result, checks version, renderer, `drm_override.so` and the patched
`vc4.ko` (md5 hard-coded in the script: update it with the module),
compresses with xz, copies the `.img.xz` and `_sha256.txt` to
`$MAC_REPO/build/` and deletes the copies in the VM.

## Steps

1. **Clone the tag.** An image of a released version is built from that
   tag, never from `main`: `git clone` the main checkout (a clone, not a
   worktree: the script needs a `.git` directory) to
   `/Users/fabio/pgen-image-<ver>`, `git checkout v<ver>`,
   `git remote set-url --push origin PUSH-DISABLED`, then copy in the
   local-only `tools/`, `build/runtime-cache/` and `t/`.
2. **Run the suite in the clone.** `t/` is not versioned: run the full
   suite (`prove -j16 -Q --state=slow,save --statefile=t/.prove-state -r t`)
   in the clone first. A red file there is acceptable only if it tests
   code after the tag (birth time `stat -f %SB` after the release's
   `publishedAt`, and a later commit it belongs to); remove those from the
   clone's `t/` and name them. Any other red stops the build.
3. **Build.** Start it detached and poll the log:
   `prlctl exec pgen-build 'MAC_REPO=/media/psf/Home/pgen-image-<ver> nohup bash /media/psf/Home/pgen-image-<ver>/tools/image-build/run-in-vm.sh > /root/image-build-<ver>.log 2>&1 &'`
   Wait for `^ERROR` or `] Done: ` in the log (a `pgrep -f run-in-vm`
   watcher matches its own command line and never ends). The log must end
   in "Output image OK" and "Done", and must not say "node not found"
   (nodejs is installed in the VM since 2026-11-16; the release
   checks parse the WebUI JS with it). How `t/` runs there:
   - as root on Linux: a test that needs macOS or a non-root user skips
     there, it does not fail.
   - The VM has no headless Chrome or Playwright, no clang and no expect,
     and cannot run the macOS-only tests: run-in-vm.sh and
     run-in-vm-pi5.sh accept exactly those skip reasons
     (`VM_SKIP_REASONS`, the same value in both, `t/release_order.t`;
     passed as `PGEN_ALLOW_SKIPPED_REASONS`), so the build goes on and the
     log lists those files under "Warning: tests skipped parts this
     machine cannot run"; the Mac's release gate runs them.
   - The tests that need SDL3 headers or numpy run there (`libsdl3-dev`,
     `python3-numpy` in the VM since 2026-11-23).
   - Any other skip stops the build (an inherited `PGEN_ALLOW_SKIPPED=1`,
     `PGEN_RELEASE_PREFLIGHT_DONE=1` or `PGEN_SKIP_RELEASE_CHECKS=1` is
     dropped there: an image built by these scripts always runs the
     checks).
   - `t/pg_v4l2_runtime.t` and `t/pg_drm_player_runtime.t` run only there
     (Linux, `libdrm-dev` installed in the VM since 2026-11-19; the
     scripts refuse to start without it; the target builds use their
     chroots, not these headers).
4. **Upload.** GitHub limits assets to 2 GiB: split the `.img.xz` into
   `.001` (1992294400 bytes) and `.002`, write `<name>.img.xz.sha256` for
   the joined file, upload the three with
   `gh release upload v<ver> -R BlackJoker90/rampecho`, then compare sizes
   and GitHub's per-asset sha256 digest with the local parts.
5. **Notes.** Add a "Flashing the image" section (join, check, flash;
   Export / Import System Settings) with `gh release edit --notes-file`;
   on a release that is not "latest" pass `--latest=false`.
6. **Afterwards.** The VM copy is gone (the script deletes it); the Mac
   copies in `build/` and the clone are deleted on the maintainer's word.

Uploads and release edits need the maintainer's OK (CLAUDE.md).

## What an image is

- From 3.0.2 the image boots without the initramfs: the builder runs
  `update-migrations.d/3.0.2-boot-no-initramfs.sh` on it (the script OTA
  devices run), and `run-in-vm.sh` checks `root=PARTUUID`, the commented
  initramfs line and that `/boot/loader/boot_dir` (the WebUI's copy of the
  boot files) equals the boot partition. An image of an older tag keeps
  the initramfs.
- An image serves its MAJOR.MINOR family: the updater only offers updates
  within it (`same_ota_family`), so a device of another family re-flashes.
