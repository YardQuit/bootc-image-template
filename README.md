# Myimage

A template for building your own bootable container image (a "bootc" image):
a full operating system defined by a `Containerfile`, built by GitHub Actions,
published to `ghcr.io`, and installed with `bootc switch` or from an ISO.

Everything here is plain YAML, TOML and Bash - no build tool to install, no
generated files, nothing hidden.

## What you get out of the box

The template is not an empty shell - it builds a usable desktop image as it
stands, and every default below is a plain, commented line in
`build_files/build.sh` or `build_files/rpm_packages` that you can delete:

- **A graphical boot.** plymouth, plus the `rhgb quiet` kernel arguments, plus
  an initramfs that actually contains plymouth - see "Graphical boot" below.
  This works even on `fedora-bootc`, which ships none of the three.
- **Automatic updates, staged not applied.** `bootc-fetch-apply-updates.timer`
  is enabled, with a drop-in that removes `--apply`, so a new image downloads
  quietly and goes live at your next reboot. Nothing reboots under you.
- **A working `/etc/cron.daily`.** `cronie-anacron` and `crontabs` are
  installed and `crond` enabled; anacron catches up jobs whose window was
  missed while the machine was off.
- **`tuned` and `firewalld`** installed and enabled.
- **Emacs with Donkey modal editing.** Every new user account starts with a
  ready-made XDG-native Emacs configuration
  ([Donkey](https://github.com/YardQuit/donkey) enabled, `~/.emacs.d` never
  created) - see "Emacs and Donkey" below.
- **A sensible package set** - `bat`, `btop`, `distrobox`, `fastfetch`, `fzf`,
  `helix`, `htop`, `neovim`, `podman-compose`, `ripgrep`, `tmux`, `zoxide` and
  a few more, all in one flat alphabetical list.

Commented examples, off by default, cover packages that install into `/opt`
(1Password, MEGAsync), COPR repos, third-party repos, requiring a YubiKey for
`sudo`, changing the firewalld default zone, and rebranding `/etc/os-release`.

## What you need

- A GitHub repository (the workflows publish to that repository's `ghcr.io`).
- `podman` if you want to build locally. Nothing else is required for CI.

## Quick start

1. Copy these files into your repository.
2. Set the name of your image (and your GitHub user or organisation):

   ```bash
   ./scripts/set-image-name.sh mydesktop myorg
   ```

   The second argument is your GitHub account or organisation handle - the part
   between `github.com/` and the repository name - not your display name.

   Type the name in whatever case you like; the script normalises it per file,
   because the same name is needed in three forms at once:

   | form | where | example |
   | --- | --- | --- |
   | lowercase | every image reference - registries reject uppercase | `ghcr.io/myorg/myimage` |
   | Capitalised | prose, this README's title | `Myimage` |
   | UPPERCASE | the ISO filename | `Fedora-MYIMAGE-Atomic-44….iso` |

   The owner is always lowercased. One caveat: renaming is a whole-word text
   substitution across the repository, README prose included, so avoid naming
   your image after an ordinary English word that appears here. The script
   refuses what would corrupt a later rename, listing the collisions it
   found: an image name that already appears in the build-critical files
   (`donkey`, `emacs`, `build` and the like), an owner that appears anywhere
   in the rewritten files - README prose included, since the owner
   substitution rewrites prose too - and a name and owner that overlap each
   other as whole words.

3. Choose a base image in `Containerfile`, and list the packages you want in
   `build_files/rpm_packages`.
4. Commit and push to your default branch. The build workflow triggers on
   `main` and `master` and publishes `ghcr.io/myorg/mydesktop:latest` from
   whichever is your repository's default; if yours is named something else,
   add it to the two branch lists in `.github/workflows/build.yml`.
5. On the machine you want to run it:

   ```bash
   sudo bootc switch ghcr.io/myorg/mydesktop:latest
   systemctl reboot
   ```

   From an existing `rpm-ostree` system, use
   `rpm-ostree rebase ostree-unverified-registry:ghcr.io/myorg/mydesktop:latest`
   instead.

The first push also creates the package on GitHub. It starts out **private** -
open *Packages -> your image -> Package settings* and make it public if you
want to install it without logging in to `ghcr.io`.

## What each file does

| File | Purpose |
| --- | --- |
| `Containerfile` | The image recipe: which base image, and to run `build.sh`. |
| `build_files/build.sh` | Everything done inside the image: copy files, install packages, enable services. |
| `build_files/rpm_packages` | The package list, one per line. Comments allowed. |
| `build_files/sysfiles/` | Files copied into the image, mirroring the real layout (`sysfiles/etc/foo` -> `/etc/foo`). |
| `build_files/sysfiles/etc/skel/.config/emacs/` | Default per-user Emacs configuration, seeded into every new user account. |
| `build_files/sysfiles/usr/lib/tmpfiles.d/10-image-var-dirs.conf` | Recreates the `/var` directories the installed packages expect, on every boot. |
| `build_files/sysfiles/usr/lib/bootc/kargs.d/00-graphical-boot.toml` | Kernel arguments (`rhgb quiet`) so plymouth draws a boot splash. |
| `build_files/sysfiles/usr/lib/systemd/system/bootc-fetch-apply-updates.service.d/10-stage-only.conf` | Makes the update timer stage updates without rebooting. |
| `disk_config/disk.toml` | Partitioning and users for VM disk images. |
| `disk_config/iso.toml` | Installer settings for the ISO. |
| `scripts/set-image-name.sh` | Renames the image everywhere in this repository. |
| `scripts/build.sh` | Builds the container locally. |
| `scripts/build-disk.sh` | Builds an ISO or VM disk locally. |
| `.github/workflows/build.yml` | Builds and publishes the container image. |
| `.github/workflows/build-disk.yml` | Builds the installer ISO on demand. |
| `.github/dependabot.yml` | Keeps the actions used by the workflows up to date. |

## Customising the image

**Packages** - add them to `build_files/rpm_packages`, one per line. It is one
flat alphabetical list rather than grouped sections, so a name is easy to find
and easy to slot in. Check a name first with `dnf info <package>`.

**Files** - drop them under `build_files/sysfiles/` using the path they should
have in the image. For example `build_files/sysfiles/etc/motd.d/10-welcome`
becomes `/etc/motd.d/10-welcome`.

**Services, config edits, extra repositories** - `build_files/build.sh` has a
commented example for each of these (COPR repos, RPMs from a URL, `systemctl
enable`, editing config files with `sed`).

**A different base** - change the second `FROM` line in `Containerfile`. The
file lists the common Fedora and CentOS options.

Two things are worth knowing when you write build steps:

- `/var` is reset on every deployment, so a directory created during the build
  never reaches a freshly installed machine. Add a line to
  `build_files/sysfiles/usr/lib/tmpfiles.d/10-image-var-dirs.conf` instead, and
  systemd-tmpfiles recreates it on every boot. `bootc container lint` names any
  directory that still needs one, and the build is warning-free as it stands -
  so a new warning means a package you added brought a directory with it.
- The build fails on the final `bootc container lint` if the image is not a
  valid bootable container - that check is there to catch mistakes early.

## Packages that install into /opt

Chrome and a number of vendor RPMs install into `/opt`, and on Fedora's
ostree-based images `/opt` is a symlink to `/var/opt`. `/var` belongs to the
machine, not to the image: it is filled in when a system is first installed and
left alone afterwards. A package installed into `/opt` during the build
therefore never reaches a machine that switches to your image, and never
updates on one that already has it.

`build_files/build.sh` section 2 has a commented block that turns `/opt` into a
real directory before packages are installed, which puts the content in the
image where `bootc upgrade` manages it. Uncomment it if you need such a
package. The trade-off is that `/opt` becomes read-only on the running system,
so you can no longer put files there by hand.

Sections 2a and 2b right below it are complete worked examples - 1Password and
MEGAsync, both installed straight from a "latest" URL with no repository -
which you can enable by uncommenting them.

If the application also wants to write inside its own directory, move that
directory to `/var` and leave a symlink behind - the approach the bootc
documentation recommends:

```bash
dnf5 -y install examplepkg
mv /opt/examplepkg/logs /var/log/examplepkg
ln -sr /var/log/examplepkg /opt/examplepkg/logs
```

Directories under `/var` that must exist on a fresh machine belong in a
systemd-tmpfiles rule rather than in the build - add
`build_files/sysfiles/usr/lib/tmpfiles.d/examplepkg.conf` with a line like
`d /var/log/examplepkg 0755 root root -`.

Background: [bootc filesystem](https://bootc.dev/bootc/filesystem.html) and
[building guidance](https://bootc.dev/bootc/building/guidance.html).

## How the image identifies itself

Out of the box the image reports itself as whatever base it was built from -
`hostnamectl`, the desktop's About page, fastfetch and the bootloader entries
all read `/etc/os-release`, and nothing in this template changes it. Section 9a
of `build_files/build.sh` is a commented example that rebrands it:

```
VERSION="44.20260819.0 (MYIMAGE Atomic)"
PRETTY_NAME="Fedora Linux 44.20260819.0 (MYIMAGE Atomic)"
VARIANT="MYIMAGE Atomic"
VARIANT_ID=myimage-atomic
IMAGE_ID=myimage
IMAGE_VERSION="44.20260819.0"
DEFAULT_HOSTNAME="myimage"
HOME_URL / DOCUMENTATION_URL / SUPPORT_URL / BUG_REPORT_URL -> your repository
```

The version is not hardcoded: it is read back out of the base's own `VERSION`,
so it follows the base forward on its own. The example also deletes the
`REDHAT_BUGZILLA_*` and `REDHAT_SUPPORT_*` keys, so `abrt` stops offering to
file crashes in your image against Fedora's Bugzilla.

`NAME`, `ID`, `VERSION_ID`, `CPE_NAME`, `LOGO` and `ANSI_COLOR` are left as the
base set them. The distribution underneath really is Fedora (or CentOS), and
vulnerability scanners match its advisories on `CPE_NAME`. Rewriting `ID` is
what forces Universal Blue to patch `grub2-switch-to-blscfg` and
`/etc/system-release` afterwards to undo the fallout - worth knowing before you
follow them there.

Because `NAME` and the leading field of `VERSION` are untouched, the ISO name
CI derives from them is unaffected.

## Building locally

```bash
./scripts/build.sh                  # localhost/myimage:latest
./scripts/build-disk.sh iso         # installer ISO   -> ./output/
./scripts/build-disk.sh qcow2       # VM disk image   -> ./output/
```

A local container build is a good way to test package names quickly; you do not
need to push to test whether the image builds.

## ISOs in CI

Go to *Actions -> Build ISO -> Run workflow*. It builds from the image already
published to `ghcr.io`, so run the container build first.

The ISO is named after what is inside the image rather than after anything
hardcoded, so changing the base in the `Containerfile` renames it by itself:

```
Fedora-MYIMAGE-Atomic-44.20260819.0.iso     # from a Fedora base
CentOS-MYIMAGE-Atomic-10.iso                # from a CentOS Stream base
```

The distribution and version come from the image's `/etc/os-release`, and the
image name from `IMAGE_NAME`, uppercased. `Atomic` is fixed text - edit it in
`.github/workflows/build-disk.yml` if it does not suit your base.

By default the ISO is attached to the run as an artifact. Tick *Upload to S3*
instead to send it to object storage, which needs these repository secrets:

| secret | example |
| --- | --- |
| `S3_PROVIDER` | `Minio`, `Cloudflare`, `Wasabi`, `AWS` … |
| `S3_ACCESS_KEY_ID` | |
| `S3_SECRET_ACCESS_KEY` | |
| `S3_REGION` | `us-east-1` |
| `S3_ENDPOINT` | `https://s3.example.com` |
| `S3_BUCKET_NAME` | `my-isos` |

Each build lands under a dated prefix (`20260819/…`) so a new ISO never
overwrites an older one.

Only ISOs are built in CI. `scripts/build-disk.sh` still builds `qcow2` and
`raw` locally, using `disk_config/disk.toml`.

## Keeping machines up to date

Machines update themselves, but they never reboot themselves.

`bootc-fetch-apply-updates.timer` is enabled in section 8 of
`build_files/build.sh`. It ships with the `bootc` package, disabled out of the
box; here it is switched on, together with a drop-in at
`build_files/sysfiles/usr/lib/systemd/system/bootc-fetch-apply-updates.service.d/10-stage-only.conf`
that replaces the stock `bootc upgrade --apply` with a plain `bootc upgrade`.

That distinction is the whole point. `--apply` reboots the moment a new image
has been staged, which on a desktop means losing whatever you were in the middle
of at a time you did not choose. Without it, the update is fetched and staged in
the background and goes live at your next reboot, via
`ostree-finalize-staged.service`. Delete the drop-in to get the stock behaviour
back.

The schedule is the stock one: an hour after boot, then every 8 hours with up to
2 hours of jitter - roughly three checks a day. Since nothing reboots, an extra
check costs only a manifest fetch and a new image gets staged sooner. Section 8
shows how to cut it to exactly once a day with a second drop-in, if you prefer.

Both units come from the `bootc` package rather than being created here, so the
drop-ins leave the distro's own files alone and survive a `bootc` update.

To update by hand at any time: `sudo bootc upgrade && systemctl reboot`.

Unlike a plain bootc base, this image does have a working `/etc/cron.daily` -
`cronie-anacron`, `crontabs` and an enabled `crond` - so a daily script dropped
in there runs. Use it for your own jobs; the image updates itself through bootc,
not through cron.

## Emacs and Donkey

`emacs` is in `rpm_packages`, and every user account created on the machine
starts with a ready-made configuration, seeded from `/etc/skel`:

| File | Purpose |
| --- | --- |
| `~/.config/emacs/init.el` | Bootstrap only: loads `config.el` and receives the blocks Customize writes. Not meant to be edited by hand. |
| `~/.config/emacs/config.el` | The configuration you edit. |
| `~/.config/emacs/donkey/donkey.el` | [Donkey](https://github.com/YardQuit/donkey), loaded and enabled from `config.el`. |

[Donkey](https://github.com/YardQuit/donkey) is an opinionated modal editing
minor-mode that layers on top of stock Emacs rather than replacing it. It is
enabled by default in every buffer; see the
[Donkey README](https://github.com/YardQuit/donkey#readme) for usage
instructions, the default keybindings and how to customise them - or press
`g ?` inside Emacs for the interactive tutor. It is not packaged in any repo,
so section 1a of `build_files/build.sh` fetches `donkey.el` at image build
time, pinned to a commit and verified against a sha256 - it is executable
elisp that lands in every user account, so the fetch is tamper-evident rather
than tracking a branch. To move to a newer Donkey, the comment there shows
both steps: `git ls-remote` to look up the commit you want, and a `curl |
sha256sum` line to compute its hash. To remove
Donkey but keep Emacs, delete its block in `config.el` and section 1a; to
remove both, also drop `emacs` from `rpm_packages`.

Three things are deliberate about the layout:

- **`~/.emacs.d` is never created - on an account that starts with this
  configuration.** Because `~/.config/emacs` exists before the first Emacs
  start, Emacs adopts it as its one directory - packages, the
  `auto-save-list/` session directory and eln-cache land there too (the
  `#file#` auto-saves themselves sit next to the file being edited, as in
  stock Emacs). This only works because the build deletes the starter
  `/etc/skel/.emacs` that Fedora's `emacs-common` package ships: `~/.emacs`
  outranks `~/.config/emacs`, so left in place it would win in every new
  account and this configuration would never load. The same applies by
  hand: a `~/.emacs`, `~/.emacs.el` or `~/.emacs.d` you create yourself
  takes precedence and disables this configuration, so don't.
- **Customize output stays out of `config.el`.** `custom-file` is left unset
  on purpose, which makes Customize save its `custom-set-variables` blocks
  into `init.el` - machine-written forms in one file, hand-written
  configuration in the other. Note that Customize's values are applied after
  `config.el`, so they win when both set the same variable.
- **`/etc/skel` only reaches new accounts** - ones created after the machine
  runs this image, the ISO's install-time user included. An account that
  existed before keeps its home untouched, and there the guarantee above
  inverts itself: with no `~/.config/emacs` present, Emacs falls back to
  `~/.emacs` as the init file it would create and `~/.emacs.d` as its
  directory - the first session makes `~/.emacs.d`, the first Customize save
  (Donkey's terminal-denylist command is one) writes `~/.emacs`, and once
  either exists it permanently outranks `~/.config/emacs`. To move such an
  account onto this configuration, salvage anything you keep in those files,
  then:

  ```bash
  rm -rf ~/.emacs ~/.emacs.el ~/.emacs.d
  cp -r /etc/skel/.config/emacs ~/.config/
  ```

  The next Emacs start adopts `~/.config/emacs` and nothing recreates the
  old paths.

`wl-clipboard` is installed alongside, so Donkey's clipboard integration works
in terminal frames (`emacs -nw`, `emacsclient -t`) on Wayland; graphical Emacs
does not need it.

## Signing (optional)

The build workflow signs published images if you give it a key, and quietly
skips signing if you don't.

```bash
cosign generate-key-pair          # creates cosign.key and cosign.pub
```

Add the contents of `cosign.key` as a repository secret named
`SIGNING_SECRET` (*Settings -> Secrets and variables -> Actions*), commit
`cosign.pub`, and never commit `cosign.key` - `.gitignore` already excludes it.

Others can then verify an image with:

```bash
cosign verify --key cosign.pub ghcr.io/myorg/myimage:latest
```

### Verifying updates on the running system

Signing only helps if the machine checks the signature before installing an
update. That is off by default: `bootc upgrade` will happily pull an unsigned
image unless you tell it otherwise. To turn it on, add three things to the
image - none of this is in the template, because it only makes sense once you
actually have a key.

1. **Ship the public key.** Add to the `ctx` stage in `Containerfile`:

   ```dockerfile
   COPY cosign.pub /cosign.pub
   ```

   and install it in `build_files/build.sh`:

   ```bash
   install -Dm0644 /ctx/cosign.pub /etc/pki/containers/myimage.pub
   ```

2. **Let containers/image look for the signature.** Already done - the template
   ships
   `build_files/sysfiles/etc/containers/registries.d/sigstore-attachments.yaml`,
   and `scripts/set-image-name.sh` keeps the repository in it up to date. It is
   inert on its own: it only says "look for an attachment", never "require one",
   so unsigned images keep pulling normally until you add step 3.

   (containers/image reads this only from `/etc/containers/registries.d` - there
   is no `/usr` location, so it has to ship under `sysfiles/etc/`.)

3. **Require a valid signature.** This one cannot be shipped as a file: it has
   to *merge* into the `/etc/containers/policy.json` the base image already
   provides, and dropping a replacement into `sysfiles/` would overwrite that
   file wholesale, discarding the defaults that let every other image be pulled.
   So add this to `build_files/build.sh` instead:

   ```bash
   python3 - <<'POLICY'
   import json, pathlib
   path = pathlib.Path("/etc/containers/policy.json")
   policy = json.loads(path.read_text())
   policy.setdefault("transports", {}).setdefault("docker", {})[
       "ghcr.io/myorg/myimage"
   ] = [
       {
           "type": "sigstoreSigned",
           "keyPath": "/etc/pki/containers/myimage.pub",
           # A cosign signature carries only a repository, never a tag, so
           # matchRepository is the only identity check that can succeed. The
           # default (matchRepoDigestOrExact) rejects every signature.
           "signedIdentity": {"type": "matchRepository"},
       }
   ]
   path.write_text(json.dumps(policy, indent=4) + "\n")
   POLICY
   ```

Two things worth knowing before you enable this:

* It makes verification **mandatory** for that repository. If signing ever
  breaks, `bootc upgrade` refuses to install rather than silently accepting an
  unverified image - which is the point, but it does mean a broken signing step
  now blocks updates.
* cosign 3.x writes signatures in the OCI 1.1 referrers format, which
  containers/image cannot read yet. `build.yml` pins cosign to the 2.x series
  for exactly this reason; if you unpin it, verification will start failing with
  *"A signature was required, but no signature exists"* even though the image is
  signed.

You can check the whole chain from any machine with podman, without rebooting:

```bash
skopeo copy --policy /etc/containers/policy.json \
  docker://ghcr.io/myorg/myimage:latest dir:/tmp/verify-test
```

## Graphical boot

A splash screen instead of a wall of kernel messages needs three things, and a
plain `fedora-bootc` base has none of them:

1. `plymouth` and `plymouth-system-theme` installed - both are in
   `rpm_packages`.
2. plymouth *inside the initramfs*. This is the part that catches people out:
   the initramfs is prebuilt in the base image, and layering a package on top
   does not change it. Section 9b of `build_files/build.sh` regenerates it with
   `dracut` - but only if the base has not already done it, so on a desktop base
   such as Silverblue or COSMIC nothing is rebuilt and no build time is spent.
3. the `rhgb` kernel argument, shipped as
   `build_files/sysfiles/usr/lib/bootc/kargs.d/00-graphical-boot.toml` and
   applied by `bootc` when the image is installed or switched to. `bootc
   container lint` parses that file during the build, so a syntax error there
   fails CI rather than shipping.

The build then checks the finished initramfs really does contain plymouth,
because the failure mode otherwise is a silent one: the image boots fine, just
to a text console.

While `dracut` runs it prints `dracut-install: ERROR: installing '/root'`. That
comes from the base image's own dracut configuration - it happens with or
without plymouth - and dracut still exits 0 and writes a working initramfs.

To go back to a text boot, delete the `kargs.d` file; to change the theme, set
`Theme=` in `/etc/plymouth/plymouthd.conf` via `sysfiles`.

## Deliberately not included

**Rechunking.** Re-splitting a finished image into evenly sized layers can cut
update download sizes several-fold, and you will see it in other image build
pipelines. It is left out here on purpose: it adds 6-10 minutes to every build,
it needs rootful podman and a reload of the image before pushing, it strips the
labels so they have to be reapplied, and the rechunked image is not identical to
the one you tested - permissions under directories such as systemd and polkit
can be relaxed, which has caused boot failures on desktops its authors had not
tested. If you decide you want it, build a disk image from the result and boot
it before switching a real machine to it.

## Why the workflows use podman directly

Container-build actions such as `redhat-actions/buildah-build` and
`redhat-actions/push-to-registry` override the container storage driver with
`fuse-overlayfs` whenever `/etc/containers/storage.conf` says `driver =
"overlay"` - which the GitHub runner images do. Every write then goes through
FUSE, and build times grow several times over (one real image went from ~12 to
~60 minutes; the commit phase alone went from 2 to 33 minutes).

Calling `podman build`, `podman push` and `podman run` directly avoids that, and
has the pleasant side effect that the workflows read like the commands you would
type yourself.
