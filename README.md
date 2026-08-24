# Myimage

A template for building your own bootable container image (a "bootc" image):
a full operating system defined by a `Containerfile`, built by GitHub Actions,
published to `ghcr.io`, and installed with `bootc switch` or from an ISO.

Everything here is plain YAML, TOML and Bash - no build tool to install, no
generated files, nothing hidden.

<!-- toc -->

- [What you get out of the box](#what-you-get-out-of-the-box)
- [What you need](#what-you-need)
- [Quick start](#quick-start)
- [What each file does](#what-each-file-does)
- [Customising the image](#customising-the-image)
- [Packages that install into /opt](#packages-that-install-into-opt)
- [How the image identifies itself](#how-the-image-identifies-itself)
- [Building locally](#building-locally)
- [Checks](#checks)
  - [Removing the tests](#removing-the-tests)
- [ISOs in CI](#isos-in-ci)
- [Keeping machines up to date](#keeping-machines-up-to-date)
- [Updating from the template](#updating-from-the-template)
- [Emacs and Donkey](#emacs-and-donkey)
- [Signing (required)](#signing-required)
  - [Verifying updates on the running system](#verifying-updates-on-the-running-system)
  - [Building without signatures](#building-without-signatures)
- [Graphical boot](#graphical-boot)
- [Deliberately not included](#deliberately-not-included)
- [Why the workflows use podman directly](#why-the-workflows-use-podman-directly)
- [License](#license)

<!-- /toc -->

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

- **The image identifies as itself.** `/etc/os-release` is rebranded with your
  image's name and repository URLs (kept in step by `set-image-name.sh`), so
  About pages and bug-report links point at you, not at the base - see "How
  the image identifies itself" below.
- **Signed, verified updates.** CI signs every published image and the image
  refuses to update to anything unsigned. This one needs something from you -
  a cosign key pair, see "Signing" below - and the first build fails until it
  has one.

Commented examples, off by default, cover packages that install into `/opt`
(1Password, MEGAsync), COPR repos, third-party repos, requiring a YubiKey for
`sudo`, and changing the firewalld default zone.

## What you need

- A GitHub repository (the workflows publish to that repository's `ghcr.io`).
- `cosign`, once, to create the signing key pair the build requires - see
  "Signing" below.
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

3. Create your signing key pair - the build requires one, see "Signing"
   below:

   ```bash
   cosign generate-key-pair          # press Enter twice for no passphrase
   mv cosign.pub build_files/cosign.pub
   ```

   Then add the contents of `cosign.key` as a repository secret named
   `SIGNING_SECRET`.
4. Choose a base image in `Containerfile`, and list the packages you want in
   `build_files/rpm_packages`.
5. Commit and push to your default branch. The build workflow triggers on
   `main` and `master` and publishes `ghcr.io/myorg/mydesktop:latest` from
   whichever is your repository's default; if yours is named something else,
   add it to the two branch lists in `.github/workflows/build.yml`. The ISO
   workflow is manual, and `checks.yml` runs on every branch, so neither needs
   that edit.
6. On the machine you want to run it:

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

Each build publishes one version carrying three tags - `latest`, the date, and
`latest.<date>`, all the same digest - and a nightly schedule would otherwise
leave a version per day on the package page forever. The `prune` job in
`build.yml` keeps the 30 most recent and deletes the rest; `latest` always
rides the newest, so it can never be pruned away. Change
`min-versions-to-keep`, or delete the job to keep everything.

## What each file does

| File | Purpose |
| --- | --- |
| `Containerfile` | The image recipe: which base image, and to run `build.sh`. |
| `build_files/build.sh` | Everything done inside the image: copy files, install packages, enable services. |
| `build_files/rpm_packages` | The package list, one per line. Comments allowed. |
| `build_files/cosign.pub` | Your signing public key - you add this; updates are verified against it. |
| `build_files/sysfiles/` | Files copied into the image, mirroring the real layout (`sysfiles/etc/foo` -> `/etc/foo`). |
| `build_files/sysfiles/etc/skel/.config/emacs/` | Default per-user Emacs configuration, seeded into every new user account. |
| `build_files/sysfiles/usr/lib/tmpfiles.d/10-image-var-dirs.conf` | Recreates the `/var` directories the installed packages expect, on every boot. |
| `build_files/sysfiles/usr/lib/bootc/kargs.d/00-graphical-boot.toml` | Kernel arguments (`rhgb quiet`) so plymouth draws a boot splash. |
| `build_files/sysfiles/usr/lib/systemd/system/bootc-fetch-apply-updates.service.d/10-stage-only.conf` | Makes the update timer stage updates without rebooting. |
| `disk_config/disk.toml` | Partitioning and users for VM disk images. |
| `disk_config/iso.toml` | Installer settings for the ISO. |
| `scripts/set-image-name.sh` | Renames the image everywhere in this repository; `--check` reports placeholders the template left behind. |
| `scripts/build.sh` | Builds the container locally. |
| `scripts/build-disk.sh` | Builds an ISO or VM disk locally. |
| `tests/` | Tests for the template's own scripts and README. Need no network, podman or root. |
| `.github/workflows/build.yml` | Builds and publishes the container image, and prunes old versions. |
| `.github/workflows/build-disk.yml` | Builds the installer ISO on demand. |
| `.github/workflows/checks.yml` | ShellCheck, the rename tests, and a parse of every YAML and TOML file. |
| `.github/dependabot.yml` | Keeps the actions the workflows use up to date. The base image is left to you. |
| `LICENSE` | MIT. Replace the copyright line with your own name if you build on this. |

## Customising the image

**Packages** - add them to `build_files/rpm_packages`, one per line. It is one
flat alphabetical list rather than grouped sections, so a name is easy to find
and easy to slot in. Check a name first with `dnf info <package>`.

A name the repos do not provide does not fail the build - `--skip-unavailable`
is deliberate, because a new Fedora release renames, merges and drops packages,
and failing there would block the release upgrade itself until every name had
been chased down. Better to take the new base and reconcile the list after. So
that a missing package is not simply invisible, the build writes down what did
not arrive:

| Where | What |
| --- | --- |
| the build log | a `### PACKAGES NOT INSTALLED` block |
| the run summary | the same list, on the workflow run page in CI |
| `/usr/share/image-build/skipped-packages` | in the image, readable on the machine |
| `/usr/share/image-build/rpm_packages` | what that image asked for, to compare against |

Both files are always present, so an empty `skipped-packages` means everything
on the list is installed. After a base-image bump, that file is the to-do list.

They ship *inside the image*, so the machine can answer the question long after
the build log has expired:

```bash
cat /usr/share/image-build/skipped-packages       # what did not arrive
grep -x helix /usr/share/image-build/rpm_packages # was it even asked for?
```

Between them those two answer the question you actually have when a tool is
missing on a running machine: did I forget to add it, or did the repos stop
providing it? Neither is visible from the machine otherwise.

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
- The build ends on `bootc container lint`, which fails if the image is not a
  valid bootable container. Its *warnings* do not fail the build - they are
  lifted onto the CI run summary instead, beside the skipped-package list.

  That split is deliberate, and it was briefly the other way round. Warnings
  describe a system that boots and then misbehaves (the `/var` case above is
  one), so they are worth reading - but they fire on ordinary packages rather
  than on mistakes. Add `cups` and `postgresql-server` and you get `/run/cups`
  and `/var/lib/pgsql`, which is simply what those packages are; with
  `--fatal-warnings` that is a failed build for doing the one thing this
  template exists to let you do. Add the flag in the `Containerfile` if you
  want them enforced, and expect to pair it with `--skip <name>` as your
  package list grows; `bootc container lint --list` names every check.

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

`hostnamectl`, the desktop's About page, fastfetch and the bootloader entries
all read `/etc/os-release`, and left alone it says whatever the base says and
points every support URL at that project's tracker. Section 9a of
`build_files/build.sh` therefore rebrands it by default - the names come from
the same placeholders `set-image-name.sh` rewrites, so after the Quick start
rename the image already identifies as yours (delete the section to keep the
base's identity instead):

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
so it follows the base forward on its own. The section also deletes the
`REDHAT_BUGZILLA_*` and `REDHAT_SUPPORT_*` keys, so `abrt` stops offering to
file crashes in your image against Fedora's Bugzilla, and it verifies its own
edits - a rename that half-missed these values fails the build rather than
shipping an image with a mixed identity.

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

`./scripts/build-disk.sh --check qcow2` runs the checks a real build would -
which config file it would read, and the placeholder-password refusal below -
and stops there, so you can ask "would this build?" without waiting for one.

`build-disk.sh qcow2` and `raw` read `disk_config/disk.toml`, which defines the
account you log in with. It ships with the placeholder password `changeme` on a
user in `wheel`, and the script refuses to build while it says that - a disk
image built from it unedited would have a sudo login whose password is written
down in a public repository. Replace it with an SSH key (best), a hash from
`openssl passwd -6` (so the repository never holds the real password), or a
different password if the image never leaves your machine. The ISO is
unaffected: there Anaconda asks for a user at install time.

## Checks

```bash
for t in tests/*.test.sh; do "${t}"; done
shellcheck --severity=warning --exclude=SC1090 \
    build_files/build.sh scripts/*.sh tests/*.sh
```

| Suite | Covers |
| --- | --- |
| `tests/set-image-name.test.sh` | The rename script's guards. |
| `tests/build-disk-guard.test.sh` | The `disk.toml` placeholder-password guard. |
| `tests/readme-toc.test.sh` | That this README's table of contents still matches its headings. |

`.github/workflows/checks.yml` runs all of them on every push and pull request,
along with a parse of every YAML and TOML file in the repository. It needs no
registry and no signing key, so unlike the image build it never skips.

The rename tests run twice: once against the repository as it stands, and once
against a copy renamed to something else. That second pass is how they run for
you - a repository created from this template was renamed on day one, and a
test that assumed the template's own name was still in use would be red on your
first push for a reason that has nothing to do with your changes.

The rename script gets tests because of how it fails: it rewrites every image
reference with whole-word text substitution, and when a guard is wrong it does
not crash - it writes a plausible-looking file, the build stays green, and the
first symptom is a machine that cannot upgrade.

The `disk.toml` guard gets them for the mirror-image reason. Refusing the
placeholder is the half that is obvious to test; letting a correctly configured
file through is the half that breaks silently, and did - the first version
matched `changeme` anywhere in the file, including the comments explaining what
the placeholder is, so it refused every disk build forever.

### Removing the tests

These test the template's own scripts - `set-image-name.sh` and
`build-disk.sh` - which your project runs but does not edit, and this README's
table of contents. That makes them the template's furniture rather than yours,
and deleting them is a reasonable first thing to do in a new project:

```bash
rm -rf tests/
```

That is the whole operation. `checks.yml` discovers the suites rather than
naming them, so with the directory gone it reports "nothing to run" and stays
green; the ShellCheck step drops them from its file list the same way. No
workflow edit, no red build.

GitHub copies the entire default branch when a repository is created from a
template - there is no `.templateignore` and no way to hold a directory back -
so shipping them and making them easy to delete is as close as the mechanism
allows.

Worth keeping if you ever copy a newer `set-image-name.sh` down from upstream:
the tests are what confirm its guards still behave in your tree, and that
script fails quietly when it fails at all.

## ISOs in CI

Go to *Actions -> Build ISO -> Run workflow*. It builds from the image already
published to `ghcr.io`, so run the container build first.

The *tag* input picks which published image goes onto the ISO. It does not
decide what the installed machine follows afterwards - the kickstart in
`disk_config/iso.toml` points that at `:latest`, and it runs after the switch
bootc-image-builder writes for the tag being built, so it wins. An ISO built
from `v2` therefore installs `v2` and then tracks `:latest`. That is also what
makes a locally built ISO usable: `scripts/build-disk.sh` hands the builder
`localhost/<name>:<tag>`, which the installed machine could never reach.
Pin the tag in `iso.toml` if you would rather hold machines on a release.

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

## Updating from the template

When a fix lands in the template and you want it, copy the file down and run
the rename again with the values you already use:

```bash
./scripts/set-image-name.sh mydesktop myorg   # the same values as before
```

<!-- template-literals -->
That second run is not redundant. Every per-project name in this repository -
`IMAGE_NAME` in both workflows, the signature policy scope in
`build_files/build.sh`, the kickstart in `disk_config/iso.toml`, the
`registries.d` scope, the motd - starts life as the template's `myimage` and
`myorg`, and a file copied down from the template brings those back with it.

Running the script again is what removes them. It rewrites the template's
placeholders as well as the name in use, so a fresh copy is repaired by the
same command that renamed the repository in the first place. Nothing else
changes: files that were already correct are reported `unchanged`.

To see whether anything is stale without changing a file:

```bash
./scripts/set-image-name.sh --check
```

It lists every placeholder that outlived the rename and exits non-zero when it
finds one. Both workflows run it before they build, so a forgotten placeholder
is a red build rather than an image whose signature policy guards a repository
nobody publishes to, or an ISO that installs a system pointing at one.

One case it cannot cover: a name or owner that contains `myimage` or `myorg`
as a whole word - `myorg-labs`, say. The substitutions cannot tell the two
apart there, so both the repair and the check stand down for that value and
say so; look for it by hand after copying files down.

What none of this settles is a genuine merge, where the template and your copy
have both changed and you want both. That is still a diff you read yourself -
but it will be about the change you came for, not about names.

<!-- /template-literals -->

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

## Signing (required)

Images built from this template are signed, and the machines running them
verify that signature before installing an update. Both halves are on by
default, so a key pair is a prerequisite rather than an extra - without one
the build fails, on pull requests and nightly runs as much as on a push.

```bash
cosign generate-key-pair          # creates cosign.key and cosign.pub
```

Press Enter twice when it asks for a passphrase. CI has no terminal to type
one into, so a passphrase-protected key fails to sign with an error that
never mentions passphrases - if you do want one, add it as a second
repository secret named `SIGNING_SECRET_PASSWORD`.

Then put the public half where the build looks for it, and the private half
where the workflow looks for it:

```bash
mv cosign.pub build_files/cosign.pub    # commit this
```

Add the contents of `cosign.key` as a repository secret named
`SIGNING_SECRET` (*Settings -> Secrets and variables -> Actions*), and never
commit `cosign.key` - `.gitignore` already excludes it.

The template deliberately ships **no** key: yours is the only one that
belongs in your image, so the first build of a fresh repository fails until
you add it, with a message saying exactly this. CI also checks that
`SIGNING_SECRET` really is the private half of the committed
`build_files/cosign.pub` - before it builds or pushes anything - so a key and
a secret that drift apart show up as a red build rather than as machines that
quietly cannot update.

Others can then verify an image with:

```bash
cosign verify --key build_files/cosign.pub \
  --insecure-ignore-tlog=true ghcr.io/myorg/myimage:latest
```

`--insecure-ignore-tlog=true` is required, not optional. The signing step
passes `--tlog-upload=false`, so these signatures are deliberately not in the
public Rekor transparency log, and without the flag `cosign verify` refuses
them for being absent from a log they were never sent to. Drop both flags
together if you want the public record.

If you would rather not sign at all, see "Building without signatures" below.

### Verifying updates on the running system

Signing on its own only helps whoever runs `cosign verify` by hand: `bootc
upgrade` pulls an unsigned image happily unless the system is told to check.
Three things make it check, and all three are active in the template:

1. **Ship the public key and require a valid signature.** Section 9c of
   `build_files/build.sh` installs `build_files/cosign.pub` into the image and
   merges a `sigstoreSigned` rule for your repository into the
   `/etc/containers/policy.json` the base provides (merged rather than
   replaced, so the defaults that let every other image be pulled survive).

   The rule is scoped to the repository the workflow is actually publishing
   to, handed to the build as `IMAGE_REPO`, rather than to a second copy of
   the name kept in `build.sh`. Two values that have to agree can drift
   apart, and a rule scoped to a repository you never publish to matches
   nothing at all - which does not fail, it silently accepts every image
   unverified. A check at the end of the section fails the build if the rule
   ever stops matching your image.

2. **Let containers/image look for the signature.** Already active - the
   template ships
   `build_files/sysfiles/etc/containers/registries.d/sigstore-attachments.yaml`,
   and `scripts/set-image-name.sh` keeps the repository in it up to date. It is
   inert on its own: it only says "look for an attachment", never "require one"
   - step 1 is what makes it a requirement.

   That file ships verbatim, so unlike the policy scope it cannot follow
   `IMAGE_REPO` by itself. Section 9c checks that its scope covers the image
   being built and fails the build when it does not: a signature that is never
   fetched fails every upgrade with *"A signature was required, but no
   signature exists"*, on an image that was signed perfectly well.

   (containers/image reads this only from `/etc/containers/registries.d` - there
   is no `/usr` location, so it has to ship under `sysfiles/etc/`.)

Two things worth knowing about running this way:

* Verification is **mandatory** for that repository. If signing ever breaks,
  `bootc upgrade` refuses to install rather than silently accepting an
  unverified image - which is the point, but it does mean a broken signing step
  now blocks updates.
* cosign 3.x writes signatures in the OCI 1.1 referrers format, which
  containers/image cannot read yet. `build.yml` pins cosign to the 2.x series
  for exactly this reason; if you unpin it, verification will start failing with
  *"A signature was required, but no signature exists"* even though the image is
  signed.

You can check the whole chain from any machine with skopeo, without rebooting -
but not by pointing it at that machine's own `/etc/containers/policy.json`.
That is the *host's* policy, and on an ordinary machine it is
`insecureAcceptAnything` for everything, so the copy succeeds whether the image
was signed or not. (It may not even be at that path: the default moved to
`/usr/share/containers/policy.json` in containers-common 0.69, which is why
section 9c of `build.sh` merges into whichever of the two it finds.)

Write the two files the check actually needs instead - a policy that requires
the signature, and the registries.d entry that sends containers/image looking
for it:

```bash
mkdir -p /tmp/verify/registries.d && cd /tmp/verify
cp /path/to/your/repo/build_files/cosign.pub .

cat > policy.json <<'EOF'
{
  "default": [{ "type": "reject" }],
  "transports": {
    "docker": {
      "ghcr.io/myorg/myimage": [
        {
          "type": "sigstoreSigned",
          "keyPath": "/tmp/verify/cosign.pub",
          "signedIdentity": { "type": "matchRepository" }
        }
      ]
    }
  }
}
EOF

cat > registries.d/ghcr.yaml <<'EOF'
docker:
  ghcr.io/myorg/myimage:
    use-sigstore-attachments: true
EOF

skopeo --policy policy.json --registries.d registries.d \
  copy docker://ghcr.io/myorg/myimage:latest dir:./copy
```

An unsigned image, one signed with a different key, or one whose signature the
registry never received all fail the same way:

```
FATA[0000] Source image rejected: A signature was required, but no signature exists
```

That is the same refusal `bootc upgrade` gives on a machine running the image,
which is the point of doing it this way: it is the running system's own check,
made by hand.

### Building without signatures

Signing can be switched off, but only as a pair - the image's demand for a
signature and CI's production of one have to go together:

1. comment out every command in section 9c of `build_files/build.sh`;
2. comment out the three cosign steps in `.github/workflows/build.yml`
   ("Install cosign", "Check signing key" and "Sign image").

Drop only the first and the workflow still insists on a key nothing uses;
drop only the second and every machine keeps demanding a signature nothing
produces, which blocks updates entirely. Both files say the same at the spot
where you make the edit.

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

## License

MIT - see [LICENSE](LICENSE). The images this template builds are labelled
`org.opencontainers.image.licenses=MIT` to match, in `.github/workflows/build.yml`.

If you build on this, put your own name on the copyright line. Change both if
you relicense.
