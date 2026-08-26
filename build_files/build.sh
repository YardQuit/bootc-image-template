#!/usr/bin/bash
##
## build.sh - everything that turns the base image into your image.
## It runs inside the container during "podman build", as root.
##
##   -e  stop on the first error
##   -u  error on undefined variables
##   -x  print each command (useful in CI logs)
##   -o pipefail  a failing command in a pipe fails the whole pipe
##
## Comment style, here and in the Containerfile: "##" is commentary, meant
## to be read. A single "#" marks a real command that is commented out -
## uncomment it to enable that feature.
##
## Where enabling something takes more than one command, those commands sit
## together between two "# ----" rulers. Uncomment every line from one ruler to
## the other and the feature is on; there is nothing to find elsewhere in the
## file. A single commented command needs no rulers.
set -euxo pipefail

CTX="/ctx"   # where the Containerfile mounted build_files/


#############################################################################
## 1. Copy files into the image 
#############################################################################
##
## Anything under build_files/sysfiles/ is copied to / with the same layout,
## so build_files/sysfiles/etc/motd.d/10-welcome lands at /etc/motd.d/10-welcome.

if [ -d "${CTX}/sysfiles" ]; then
    cp -rv "${CTX}/sysfiles/." /
fi

## Make sure anything you dropped in these dirs is executable.
## Delete these lines if you don't ship scripts.
chmod -R +x /etc/cron.daily 2>/dev/null || true


#############################################################################
## 1a. Donkey - modal editing for Emacs
#############################################################################
##
## donkey.el is not packaged in any repo, so fetch it at build time and seed
## it through /etc/skel, next to the init.el/config.el that section 1 just
## copied there. Its README wants it at donkey/donkey.el inside the user's
## Emacs directory; config.el loads it from there and enables donkey-mode.
##
## The fetch is pinned to a commit and checked against a hash: this file is
## executable elisp that ends up in every account on every machine running
## the image, and a moved tag or a compromised branch would otherwise walk
## straight in. The cost is that donkey no longer updates by itself - to
## move to a newer donkey, look up the commit you want (ls-remote answers
## for a branch or a tag), hash it, and put both values below:
##
##   COMMIT=$(git ls-remote https://github.com/YardQuit/donkey master | awk '{print $1}')
##   echo $COMMIT; curl -fsSL https://raw.githubusercontent.com/YardQuit/donkey/$COMMIT/donkey.el | sha256sum

DONKEY_COMMIT="c4a61bde229420a71f30733664ad6b3ac6c336e5"   # 1.4.0
DONKEY_SHA256="3e07b21c2d94b57908e332cb200d773ca0ce4d3ea2a9623e18096e4fcb895fb5"

## The directory is created explicitly: curl's --create-dirs would make it
## 0750, and /etc/skel content must be world-readable or copying it by hand
## into an existing account fails (section 1's sysfiles copy ships 0755).

install -d -m 0755 /etc/skel/.config/emacs/donkey

## --retry absorbs the transient registry blip that would otherwise abort a
## scheduled CI build; a genuine failure still stops the build once the
## retries are spent, and a checksum mismatch stops it right here.
## A stalled transfer is aborted per attempt by --speed-limit/--speed-time
## (under 1 byte/s for 30 s), which --retry treats as transient like any
## other failure. --max-time caps each single attempt - it resets on retry,
## so it bounds nothing overall. --retry-max-time is the real outer bound:
## once it has passed, no further retries start, and the worst case is that
## bound plus one attempt. Without it a server dribbling just fast enough to
## dodge the speed check could hold the build for every retry's full
## max-time in a row.

curl -fL --retry 3 --retry-all-errors --connect-timeout 15 \
    --speed-limit 1 --speed-time 30 --max-time 120 --retry-max-time 300 \
    -o /etc/skel/.config/emacs/donkey/donkey.el \
    "https://raw.githubusercontent.com/YardQuit/donkey/${DONKEY_COMMIT}/donkey.el"

## curl creates the file with the build's umask - pin the mode the same way
## install -d pinned the directory's, or a hardened builder (umask 027) ships
## a donkey.el other users cannot read.

chmod 0644 /etc/skel/.config/emacs/donkey/donkey.el
echo "${DONKEY_SHA256}  /etc/skel/.config/emacs/donkey/donkey.el" | sha256sum -c -


#############################################################################
## 2. Packages that install into /opt
#############################################################################
##
## Skip this unless you install something that lives in /opt - Chrome, various
## vendor RPMs, some proprietary tools.
##
## On Fedora's ostree-based images /opt is a symlink to /var/opt, and /var
## belongs to the machine rather than to the image: it is filled in when a
## system is first installed and left alone from then on. A package installed
## into /opt during the build therefore never arrives on a machine that
## switches to your image, and never updates on one that already has it.
##
## Making /opt a real directory before installing anything puts that content
## inside the image, where "bootc upgrade" manages it like everything else.
## The trade-off: /opt is then read-only on the running system, so you can no
## longer drop files into /opt by hand.
##
## The 1Password and MEGAsync blocks below carry their own copy of these four
## lines, so enabling one of those needs nothing from here. Uncomment it here
## when you install some other package that lives in /opt.

# --- /opt as a real directory: uncomment to the next ruler
# --------------------------------------------------------------------------
# if [ -L /opt ]; then
#     rm /opt
#     mkdir /opt
# fi
# --------------------------------------------------------------------------

## Some applications insist on writing inside their own directory. Move those
## directories to /var and leave a symlink behind - this is what the bootc
## documentation recommends:

# --- an /opt package that writes inside its own directory
# --------------------------------------------------------------------------
# dnf -y install examplepkg
# mv /opt/examplepkg/logs /var/log/examplepkg
# ln -sr /var/log/examplepkg /opt/examplepkg/logs
# --------------------------------------------------------------------------

## A directory under /var that has to exist on a fresh machine is best created
## at boot by systemd-tmpfiles instead of here. Add the file
## build_files/sysfiles/usr/lib/tmpfiles.d/examplepkg.conf containing:
##
##   d /var/log/examplepkg 0755 root root -
##
## The alternative, if you would rather keep /opt writable, is to leave the
## symlink alone and install the application some other way on the running
## system (a container, a Flatpak, or a per-machine install).


#############################################################################
## 2a. Example of such a package: 1Password (Fedora)
#############################################################################
##
## Ready to use: uncomment every line between the rulers below, and nothing
## else in this file has to change. The optional extra further down has rulers
## of its own.
##
## The "-latest" URL always serves the current release, so each image build
## picks up whatever version is newest at that moment. Nothing is pinned; if you
## would rather build the same version every time, use the versioned file name
## instead, e.g. .../x86_64/1password-8.12.32.x86_64.rpm
##
## 1Password puts almost all of its files in /opt, which makes it the textbook
## case for section 2 - so the block below opens with those same four lines,
## rather than sending you back there to remember them.
##
## The package's install scriptlet creates the "onepassword" and
## "onepassword-mcp" groups if they are missing. A container build has no users,
## so it allocates them from the human range (1000, 1001) - the same range the
## first real user gets. Creating them as system groups first means the package
## reuses them, and the setgid helper binaries end up owned by a system group.
##
## groupadd writes them into this image's /etc/group and nowhere else, which
## "bootc container lint" reports the moment you uncomment the two lines below:
##
##   sysusers: Found /etc/group entry without corresponding systemd sysusers.d:
##     onepassword
##     onepassword-mcp
##
## A warning rather than an error, and worth acting on: /etc is per-deployment
## and merged on every update, so a group that lives only there is one a future
## merge can drop - taking the ownership of those setgid binaries with it. The
## durable half is a file systemd reads from /usr on every boot. Ship it as
## build_files/sysfiles/usr/lib/sysusers.d/10-onepassword.conf, containing:
##
##   g onepassword -
##   g onepassword-mcp -
##
## Both halves, not one or the other: the RPM below wants the groups to exist
## before it installs, and a sysusers.d file is not read until boot.

# --- 1Password: uncomment every line down to the next ruler
# --------------------------------------------------------------------------
# ## /opt has to be a real directory before anything installs into it. The same
# ## four lines as section 2, and harmless if that block is enabled as well.

# if [ -L /opt ]; then
#     rm /opt
#     mkdir /opt
# fi

# ## System groups, so the package reuses them instead of allocating from the
# ## human range. Worth pairing with the sysusers.d file described above.

# groupadd -r onepassword
# groupadd -r onepassword-mcp

# rpm --import https://downloads.1password.com/linux/keys/1password.asc
# dnf -y install https://downloads.1password.com/linux/rpm/stable/x86_64/1password-latest.rpm

# ## The package drops in a dnf repository for its own auto-updates. An image
# ## updates when you rebuild it, so the file has no purpose here.

# rm -f /etc/yum.repos.d/1password.repo
#
# ## 1Password writes its own ~/.config/autostart entry when "Start at login" is
# ## turned on in its settings. This one is here so that it does not have to be.
# ## --silent is the app's own flag - its CLI defines it as "open to the system
# ## tray without showing the main window" - and the path is the one the package's
# ## own .desktop uses. Same /etc/xdg/autostart reasoning as the MEGAsync and
# ## Trayscale blocks.
# install -d -m 0755 /etc/xdg/autostart
# cat > /etc/xdg/autostart/1password.desktop <<'DESKTOP'
# [Desktop Entry]
# Type=Application
# Name=1Password
# Icon=1password
# Exec=sh -c "sleep 5; exec /opt/1Password/1password --silent 2>/dev/null"
# Terminal=false
# X-GNOME-Autostart-enabled=true
# DESKTOP
# chmod 0644 /etc/xdg/autostart/1password.desktop
# --------------------------------------------------------------------------

## Two things the package's install step does that are worth knowing about:
##
##  * It writes /usr/share/polkit-1/actions/com.1password.1Password.policy from
##    a template, filling in the human users it finds in /etc/passwd. A
##    container build has none, so the list comes out empty. Only two of the
##    three actions in that file use the list - "authorize CLI" and "authorize
##    SSH agent" - so the browser and CLI integrations and the SSH agent are
##    what suffer; unlocking the app itself does not use it and works either
##    way.
##
##    Only if you use those integrations: install the image once, copy
##    /opt/1Password/com.1password.1Password.policy.tpl out of it, replace
##    ${POLICY_OWNERS} with "unix-user:yourname", save the result as
##    build_files/sysfiles/usr/share/polkit-1/actions/com.1password.1Password.policy
##    and uncomment the command below. It has to run here rather than in
##    section 1, which happens before the package is installed and would be
##    overwritten by it.
##
##    Leave the command commented out if you have not created that file: the
##    build stops on a missing source.

# --- 1Password, optional: the polkit policy from your own file
# --------------------------------------------------------------------------
# install -Dm0644 \
#     /ctx/sysfiles/usr/share/polkit-1/actions/com.1password.1Password.policy \
#     /usr/share/polkit-1/actions/com.1password.1Password.policy
# --------------------------------------------------------------------------

##  * It creates the "onepassword" and "onepassword-mcp" groups, sets the setgid
##    bit on two helper binaries and the setuid bit on chrome-sandbox. That all
##    happens during the build and travels in the image, which is what you want.


#############################################################################
## 2b. Example of such a package: MEGAsync (Fedora)
#############################################################################
##
## Ready to use: uncomment every line between the rulers below, and nothing
## else in this file has to change. The command-line client further down has
## rulers of its own.
##
## Same idea as 1Password, with one wrinkle: the download URL names the Fedora
## release, so it has to be kept in step with the FROM line in the Containerfile.
## There is no build for a Fedora release until MEGA publishes one, and the
## build fails loudly if you point at one that does not exist yet.
##
## MEGAsync puts its bundled ffmpeg libraries in /opt/megasync/lib, so it needs
## section 2's /opt fix - the block below opens with it. Without that, the
## application installs but its libraries disappear on the first upgrade, which
## looks like a broken app rather than a missing one.
##
## MEGAsync's %post scriptlet cannot succeed inside an image build, and neither
## of the two things it does is wanted here. It moves /var/lib/rpm/.rpm.lock
## aside to run a nested "rpm --import" for MEGA's key - ostree bases keep the
## rpm database in /usr/share/rpm and have no /var/lib/rpm at all, so the lock is
## not where it looks and the import fails. It then calls sysctl to raise
## fs.inotify.max_user_watches, which is denied in an unprivileged build.
##
## rpm still installs the package when %post fails, but dnf reports the whole
## transaction as failed and exits non-zero, which would abort the build. So
## tolerate a non-zero exit and assert afterwards that the package really landed
## - a genuine download or dependency failure still stops the build. The same
## shape works for any vendor RPM with a scriptlet that misbehaves in a container.

# --- MEGAsync: uncomment every line down to the next ruler
# --------------------------------------------------------------------------
# ## /opt has to be a real directory before anything installs into it. The same
# ## four lines as section 2, and harmless if that block is enabled as well.
# if [ -L /opt ]; then
#     rm /opt
#     mkdir /opt
# fi
#
# dnf -y install https://mega.nz/linux/repo/Fedora_44/x86_64/megasync-Fedora_44.x86_64.rpm \
#     || echo "megasync: dnf exited non-zero (expected) - verifying"
# rpm -q megasync
#
# ## As with 1Password: a dnf repository for auto-updates, of no use in an image.
# rm -f /etc/yum.repos.d/megasync.repo
#
# ## MEGAsync writes its own ~/.config/autostart entry the first time it is run
# ## and told to start on login. This one is here so that it does not have to be:
# ## a fresh account gets the tray client running without anyone opening the
# ## preferences window first. The same /etc/xdg/autostart reasoning as the
# ## Tailscale block in section 8, including how to switch it off per account.
# install -d -m 0755 /etc/xdg/autostart
# cat > /etc/xdg/autostart/megasync.desktop <<'DESKTOP'
# [Desktop Entry]
# Type=Application
# Name=MEGAsync
# Icon=mega
# Exec=sh -c "sleep 5; exec megasync 2>/dev/null"
# Terminal=false
# X-GNOME-Autostart-enabled=true
# DESKTOP
# chmod 0644 /etc/xdg/autostart/megasync.desktop
# --------------------------------------------------------------------------

## The inotify limit belongs in a sysctl.d drop-in applied at boot instead, e.g.
## build_files/sysfiles/usr/lib/sysctl.d/90-megasync-inotify.conf containing:
##
##   fs.inotify.max_user_watches = 524288

## The command line client is published the same way, if you prefer it:

# --- MEGAcmd, the command line client, instead of or as well as the above
# --------------------------------------------------------------------------
# dnf -y install https://mega.nz/linux/repo/Fedora_44/x86_64/megacmd-Fedora_44.x86_64.rpm
# --------------------------------------------------------------------------

## Note that MEGAsync is a Qt5 application. On a GNOME or COSMIC image the Qt5
## libraries are not installed, so expect dnf to pull in a sizeable dependency
## tree along with it.


#############################################################################
## 3. Install packages
#############################################################################
##
## build_files/rpm_packages is a plain list, one package per line.
## Blank lines and lines starting with # are ignored.
## grep exits 1 when it matches nothing, and under "set -e" with pipefail that
## aborts the build here - silently, with no message, and before the emptiness
## check below can say anything. Commenting out every line is a legitimate way
## to build a bare image, so it has to reach that check.

PACKAGES=$({ grep -vE '^\s*(#|$)' "${CTX}/rpm_packages" || true; } | tr '\n' ' ')

## --skip-unavailable keeps the build going when a package is missing from the
## repos. That is deliberate and worth keeping: a new release renames, merges
## and drops packages, and a hard failure there would block the base upgrade
## itself until every name in rpm_packages had been chased down. Better to get
## the new base first and reconcile the list afterwards.
##
## It only covers packages nothing else depends on, though. Section 8 enables
## tuned, firewalld and crond by name, and section 9b asserts plymouth reached
## the initramfs; lose one of those and the build still stops, just later and
## with a less obvious message. That is the right trade - those four are load-
## bearing here - but it means "the build survives a base bump" holds for the
## long tail of the package list, not for all of it.
##
## The cost is that a missing package is otherwise invisible - the build stays
## green and the tool is simply absent on the machine. So write down what did
## not arrive, both in the build log and in the image itself, where it can be
## read back long after the log has expired:
##
##   /usr/share/image-build/rpm_packages       what this image asked for
##   /usr/share/image-build/skipped-packages   what the repos did not provide
##
## Both files are always present; an empty skipped-packages means everything
## asked for is installed. CI also copies the list into the run summary.
##
## "rpm -q --whatprovides" is what decides, rather than the package name alone,
## so a name satisfied by a virtual provide or by a renamed package still
## counts as installed.
## "dnf" is the right command on every base the Containerfile offers. It
## resolves to /usr/bin/dnf5 on Fedora, Hummingbird and the Atomic Desktops,
## and to /usr/bin/dnf-3 on CentOS Stream and AlmaLinux. So there is no version
## to detect here - only a command to run, provided the flags mean the same to
## both. They do, but not the ones you would reach for first:
##
##   --skip-unavailable   dnf5 only; dnf 4 exits 2, "unknown option".
##   --skip-broken        both, but on dnf5 it covers only the broken half - a
##                        name no repository carries still fails.
##   --setopt=strict=0    both, and on both it covers the pair: a name nothing
##                        provides, and a name whose dependencies cannot be
##                        met. That is what dnf 4 documents it as, and dnf5
##                        honours it - measured, not assumed.
##
## So: one invocation rather than a branch per version. That is worth more than
## tidiness. This was two branches written to be equivalent, and they were not
## - the dnf5 side passed --skip-unavailable alone, so a repository carrying a
## package with an unmeetable dependency built on CentOS and stopped on Fedora.
## Two things that must agree eventually do not; one thing cannot disagree with
## itself.
##
## The risk traded for that is dnf5 someday dropping strict. It fails loudly if
## it does: an unrecognised --setopt is exit 2 on dnf5. And base-check.yml runs
## this exact flag against every base weekly, so it would show up there first.
##
## Everything below is spelled "dnf" for the same reason, and it matters more
## there than here: dnf5 is not installed on CentOS Stream or AlmaLinux and is
## not in their repositories either, so a line spelled "dnf5" is not a package
## that fails to install - it is "command not found" before dnf is reached at
## all. Two of them need more than the name changing, and say so where they
## are: the group example above, and the repository file in section 6.
##
## A zypper clause would go in the refusal below, and openSUSE is RPM so the
## record further down would still work. It is absent on purpose: there is no
## openSUSE bootc base image to point it at - not on registry.opensuse.org,
## registry.suse.com or quay - and an installer this template can drive is not
## the same thing as a base bootc can boot. A branch nothing can run is a
## branch nothing can test, which is how it would come to be wrong quietly.

if ! command -v dnf >/dev/null 2>&1; then
    echo "ERROR: this base has no dnf, so nothing here can install a package." >&2
    echo "Every base the Containerfile offers has one - on Fedora it is dnf5" >&2
    echo "under that name. If you changed the base, check that it is an RPM" >&2
    echo "one; the list of what is known to work is at the top of that file." >&2
    exit 1
fi

## Both installers clean up after themselves. dnf leaves repo metadata under
## /var/lib/dnf and lock files under /run, both of which land in the image and
## both of which "bootc container lint" flags - as "content in runtime-only
## directories" and "content in /var missing systemd tmpfiles.d entries". That
## used to be a single "rm -rf" in section 7, which was right only while this
## section was the last thing to run dnf. Sections 8 and 9b install too, and an
## install after that point puts the pair straight back. Cleaning inside the
## installer cannot be outlived by an install added later.

pkg_cleanup() {
    rm -rf /var/lib/dnf /run/dnf
}

## The rpm_packages list: a name that cannot be installed is recorded and the
## build carries on.

pkg_install_optional() {
    dnf install --setopt=strict=0 -y "$@"
    pkg_cleanup
}

## A package a later section needs by name: no skip flag, so a missing one
## stops the build where the package is named, rather than three sections later
## where only a systemd unit is. Safe to call for something the base already
## has - dnf says so and exits 0.

pkg_install() {
    dnf install -y "$@"
    pkg_cleanup
}

if [ -n "${PACKAGES}" ]; then
    pkg_install_optional ${PACKAGES}
fi

install -d -m 0755 /usr/share/image-build
install -m 0644 "${CTX}/rpm_packages" /usr/share/image-build/rpm_packages

rpm -q --whatprovides ${PACKAGES} 2>&1 \
    | sed -n 's/^no package provides //p' \
    > /usr/share/image-build/skipped-packages || true
chmod 0644 /usr/share/image-build/skipped-packages

if [ -s /usr/share/image-build/skipped-packages ]; then
    echo "### PACKAGES NOT INSTALLED - not in the repos, or not installable:"
    sed 's/^/###   /' /usr/share/image-build/skipped-packages
    echo "### Recorded in the image at /usr/share/image-build/skipped-packages"
fi

## Fedora's emacs-common ships a starter /etc/skel/.emacs. It arrives here -
## after section 1 copied this image's /etc/skel/.config/emacs into place -
## and ~/.emacs outranks ~/.config/emacs in Emacs's init search, so every
## account created from this skel (the installer's included) would load the
## stock file instead: Donkey never enables, and the first session grows an
## ~/.emacs.d. Remove it so new accounts get the configuration this image
## actually ships. Harmless when emacs is dropped from rpm_packages.
rm -f /etc/skel/.emacs

## Example: install a whole package group instead of single packages
## dnf group install --setopt=strict=0 -y cosmic-desktop


#############################################################################
## 4. Optional: packages from COPR repos
#############################################################################
##
## Enable the repo, install, then disable it again so the finished image does
## not keep pulling from it at runtime.
##
## Two things have to be true before this block works on a given base.
##
## "dnf copr" comes from a plugin package rather than from dnf itself. The
## Fedora bases and CentOS Stream ship it already - dnf5-plugins on the first,
## python3-dnf-plugins-core on the second - but AlmaLinux does not, and the
## subcommand is simply absent there until "dnf install -y dnf-plugins-core"
## has run.
##
## And the project has to have built for your base. "copr enable" writes a
## repository URL ending in the chroot it picked - fedora-$releasever-$basearch
## on Fedora, epel-10-$basearch on the RHEL-family bases, which pin the number -
## so a project that only builds for one of them leaves the other pointing at
## nothing. atim/lazygit builds for both; many do not.
##
## The setopt makes an outage say so. "copr enable" writes
## skip_if_unavailable=True into the repo file it generates, so when COPR
## cannot be reached dnf quietly drops the repository, prints "Repositories
## loaded" and then stops on
##
##   No match for argument: lazygit
##
## which reads as "upstream removed the package" when it means "the server was
## down for a minute". That is not hypothetical - it is how a build here
## failed, with the log naming the package rather than the outage. With it
## off you get the true reason instead:
##
##   Failed to download metadata ... for repository "copr:...:atim:lazygit"
##
## The build stops either way - these install by name, with no skip flag, and
## that is deliberate. What changes is whether the log sends you hunting for a
## renamed package or tells you to run it again.
##
## The glob keeps this to COPR repos. Fedora's own are already
## skip_if_unavailable=False; the ones that are not - openh264,
## updates-archive - are optional and meant to be skipped.

# --- lazygit from COPR: uncomment every line down to the next ruler
# --------------------------------------------------------------------------
# dnf -y copr enable atim/lazygit
# dnf -y install --setopt="copr:*.skip_if_unavailable=0" lazygit
# dnf -y copr disable atim/lazygit
# --------------------------------------------------------------------------


#############################################################################
## 5. Optional: RPMs from a URL
#############################################################################
##
## dnf can install straight from a URL - no need to download first, and no
## repository on the finished system.
## dnf -y install https://example.com/downloads/some-package.x86_64.rpm

## Sections 2a and 2b are complete, ready-to-uncomment examples of this
## (1Password and MEGAsync).
##
## Both of those import the vendor's key first, so rpm checks the signature
## before installing. Not every project signs its packages, and dnf says so
## rather than refusing:
##
##   Warning: skipped OpenPGP checks for 1 package from repository: @commandline
##
## That is worth reading rather than tuning out: it means nothing vouches for
## the file except HTTPS to the host it came from. The block below is one of
## those - there is no key to import, so there is no line importing one.
##
## Its URL carries the tag "rpm-release" rather than a version, so the address
## is fixed and the file behind it moves. Each build takes whatever is current,
## the same way section 6's installers do.

# --- CSVDT from a GitHub release: uncomment every line down to the next ruler
# --------------------------------------------------------------------------
# dnf -y install https://github.com/YardQuit/csvdt/releases/download/rpm-release/csvdt.x86_64.rpm
# --------------------------------------------------------------------------


#############################################################################
## 6. Optional: third-party repos and upstream installers
#############################################################################
##
## A repository file is fetched with curl rather than "dnf config-manager",
## because that is the one command the two dnf versions spell differently:
## "config-manager addrepo --from-repofile=URL" on dnf5, "config-manager
## --add-repo URL" on dnf 4, and each rejects the other's. A .repo file is only
## a file, so writing it where dnf looks works the same on every base, and
## needs no plugin package installed to do it.

# --- a third-party repo: uncomment every line down to the next ruler
# --------------------------------------------------------------------------
# curl -fsSL -o /etc/yum.repos.d/example.repo https://example.com/example.repo
# dnf -y install example-package
# --------------------------------------------------------------------------

## An upstream "curl | sh" installer needs one thing said to it: where to put
## the binary.
##
## They are written for a running machine, so they default to a per-user
## directory - $HOME/.local/bin most often, sometimes /usr/local/bin or /opt.
## On every base the Containerfile offers, /root and /home are symlinks into
## /var; on the Fedora Atomic desktops and Hummingbird, /usr/local and /opt are
## too. What that does to a build depends on the base, which is the awkward
## part:
##
##   Where the target does not exist in the base image - the desktops,
##   fedora-bootc, AlmaLinux - "mkdir -p" can neither follow the dangling link
##   nor replace it, so the installer stops and takes the build with it:
##
##     mkdir: cannot create directory '/root': File exists
##
##   Where it does exist - CentOS Stream and Hummingbird ship a /var/roothome -
##   the install succeeds and the binary lands in /var, which is not image
##   content. What a build writes there seeds the filesystem once, at install,
##   and is the machine's own from then on: "bootc upgrade" leaves the old copy
##   where it is, and a rollback does not take it back.
##
## So one line breaks the build on one base and quietly stops shipping the
## binary on another. Point the installer at /usr/bin and both go away - it is
## versioned with the image, upgrades with it and rolls back with it. How you
## say so varies - an environment variable in some, a flag in others - so read
## the script before piping it to a shell; either way the answer is near the
## top. One that offers neither, and no plain tarball you can unpack into
## /usr/bin yourself, does not belong in a build: install it from a package
## instead, or leave it to the user to install into their own home.
##
## The other thing a build needs from an installer is silence. Many stop to ask
## for confirmation, and a build has no terminal to answer with - starship's
## dies on "/dev/tty: No such device or address" and tells you to re-run with
## --yes. Pass whatever its version of that is.
##
## "sh -s --" below rather than plain "sh" is what lets those arguments through
## the pipe at all.
##
##
## Both blocks below also write the tool's shell completions. Generating them
## here, with the binary that was just installed, is what keeps them from
## drifting: a release that adds a subcommand ships completions that know about
## it on the next build, and there is nothing to remember to update.
##
## bash, zsh and fish, and no directory to create first - those three belong to
## the "filesystem" package rather than to zsh or fish, so they are present on
## every base whether or not those shells are, and the completions are already
## in place if one is added to rpm_packages later. Both tools also offer
## powershell and elvish, and starship offers nushell; none of those has a
## system-wide completion directory on Linux, so none is written.
##
## The subcommand is not spelled the same by both - "starship completions",
## "herdr completion" - which is the usual reason a line like this fails.
## Section 5 is the better route whenever upstream also ships an RPM.

# --- starship, from upstream's installer rather than a COPR
# --------------------------------------------------------------------------
# curl -sS https://starship.rs/install.sh | sh -s -- --yes --bin-dir /usr/bin
#
# starship completions bash > /usr/share/bash-completion/completions/starship
# starship completions zsh  > /usr/share/zsh/site-functions/_starship
# starship completions fish > /usr/share/fish/vendor_completions.d/starship.fish
# chmod 0644 /usr/share/bash-completion/completions/starship \
#            /usr/share/zsh/site-functions/_starship \
#            /usr/share/fish/vendor_completions.d/starship.fish
# --------------------------------------------------------------------------

## herdr is the other half of the pattern: it takes an environment variable
## where starship takes a flag, and it asks nothing, so there is no --yes to
## pass. Between the two blocks, both shapes you will meet are covered.

# --- herdr, an installer that takes an environment variable
# --------------------------------------------------------------------------
# curl -fsSL https://herdr.dev/install.sh | HERDR_INSTALL_DIR=/usr/bin sh
#
# herdr completion bash > /usr/share/bash-completion/completions/herdr
# herdr completion zsh  > /usr/share/zsh/site-functions/_herdr
# herdr completion fish > /usr/share/fish/vendor_completions.d/herdr.fish
# chmod 0644 /usr/share/bash-completion/completions/herdr \
#            /usr/share/zsh/site-functions/_herdr \
#            /usr/share/fish/vendor_completions.d/herdr.fish
# --------------------------------------------------------------------------


#############################################################################
## 7. Clean up
#############################################################################
##
## There is no "dnf clean all" here, and that is deliberate. The Containerfile
## mounts /var/cache and /var/log as build caches, so dnf's downloads and logs
## never become part of a layer at all - there is nothing there for a clean to
## shrink. What it would do is empty the cache those mounts exist to keep, so
## the next local build re-downloads every package and every repository index
## it had just fetched.
##
## Put it back if you drop the two --mount=type=cache lines from the
## Containerfile: without them /var/cache is ordinary image content, and a few
## hundred megabytes of it.
##
## The state dnf does leave outside those mounts - repo metadata under
## /var/lib/dnf, lock files under /run - is removed by pkg_cleanup, which runs
## as part of every install rather than once here. See section 3 for why: this
## spot is no longer after the last dnf invocation.


#############################################################################
## 8. Enable systemd units
#############################################################################
##
## The units have to exist in the image, so the packages carrying them are
## installed right here rather than left to rpm_packages. That list is one you
## are meant to rewrite, and a rewrite that drops one of these does not fail
## where you edited it - it fails here, with
##
##   Failed to enable unit: Unit tuned.service does not exist
##
## which points at systemd rather than at the line you deleted. Installing them
## beside the enable also means a feature you do not want is two adjacent lines
## to comment out, instead of an edit in two files that have to agree.
##
## podman.socket, fstrim.timer and the bootc timer further down need nothing
## added: every base the Containerfile offers already ships them.

pkg_install tuned firewalld crontabs cronie-anacron

systemctl enable podman.socket
systemctl enable fstrim.timer

## Fedora's presets already enable tuned and firewalld the moment they are
## installed - saying so here is explicit rather than depending on a preset
## that could change under you.

systemctl enable tuned.service
systemctl enable firewalld.service

## A working /etc/cron.daily. The chain is: crond runs /etc/cron.d/0hourly, which
## runs /etc/cron.hourly/0anacron, which runs anacron, which runs run-parts over
## /etc/cron.daily. Leave crond disabled and a script dropped in cron.daily
## simply never runs. Anacron rather than plain cron because a desktop is not on
## 24/7: a job whose window was missed runs at the next opportunity instead of
## being skipped for the day. /var/spool/anacron is recreated on every boot by
## the tmpfiles.d rule the cronie-anacron package ships, so it needs nothing
## from section 10.

systemctl enable crond.service

## Automatic updates. bootc ships this timer in the base image, disabled: it
## fires an hour after boot, then every 8 hours with up to 2 hours of jitter -
## roughly three checks a day, which costs nothing but a manifest fetch when
## nothing has changed.

systemctl enable bootc-fetch-apply-updates.timer

## The stock unit runs "bootc upgrade --apply", and --apply reboots the moment a
## new image has been staged: on a desktop that means losing whatever you were in
## the middle of, at a time you did not choose. The drop-in shipped at
## build_files/sysfiles/usr/lib/systemd/system/bootc-fetch-apply-updates.service.d/10-stage-only.conf
## replaces that command with a plain "bootc upgrade", so an update is fetched
## and staged quietly and goes live at your next reboot, via
## ostree-finalize-staged.service. Delete that file to get the stock
## reboot-as-soon-as-ready behaviour back.
##
## The empty ExecStart= in it is required: without it systemd appends a second
## command rather than replacing the first. Both the unit and the timer come from
## the bootc package itself, and the drop-in leaves the distro's own unit file
## untouched, so a bootc update replaces its unit and the override still applies
## on top.
##
## To check exactly once a day instead of three times, add
## build_files/sysfiles/usr/lib/systemd/system/bootc-fetch-apply-updates.timer.d/10-daily.conf
## containing:
##
##   [Timer]
##   OnBootSec=
##   OnCalendar=daily
##   RandomizedDelaySec=2h
##   Persistent=true
##
## The empty OnBootSec= is load-bearing there: assigning the empty string to any
## of the On*Sec/OnCalendar settings resets the entire trigger list, monotonic and
## calendar alike. Without it the stock 1h-after-boot and 8-hourly triggers keep
## firing alongside the daily one. Persistent=true catches up after the machine
## has been off over the scheduled time rather than skipping that day.

## One unit is masked rather than enabled. systemd-remount-fs.service reads
## /etc/fstab and remounts / with the options listed there - but on a bootc
## system / is composefs, an overlay mount, and the kernel refuses to remount
## an overlay. The unit therefore fails on every boot: a red entry in
## "systemctl --failed" and a FAILED line during boot, with no functional
## effect - root was already mounted correctly by the initramfs, and fstab
## options for / are moot on a by-design read-only root. Known upstream since
## the Fedora 42 composefs switch and unresolved (fedora-silverblue#605,
## ostree#3193 - closed as "a systemd problem" - and fedora-iot#81); it
## reproduces on stock Fedora Atomic images, nothing in this template causes
## it. On composefs the unit can never do anything useful, so masking trades
## a guaranteed failure for a clean skip. This is a workaround, not an
## upstream-blessed fix: remove it if the trackers above resolve, or if you
## ever build this image on a base that does not use composefs for /.
systemctl mask systemd-remount-fs.service

## Examples. The first needs no package: openssh-server is already installed in
## every base the Containerfile offers. The second does, so it brings its own
## install line - Fedora packages tailscale itself, in the always-enabled
## "fedora" and "updates" repos, so no third-party repo is involved.
##
## Uncommenting tailscale earns one lint warning on the next build:
##
##   var-tmpfiles: Found content in /var missing systemd tmpfiles.d entries:
##     d /var/lib/tailscale 0600 root root - -
##
## The package creates that directory and ships no tmpfiles.d rule for it, so
## on an installed machine it would simply be absent - /var is reset on every
## deployment. Paste the line lint printed into
## build_files/sysfiles/usr/lib/tmpfiles.d/10-image-var-dirs.conf, which exists
## for this and says as much at the top.

# --- SSH Server: uncomment every line down to the next ruler
# --------------------------------------------------------------------------
# systemctl enable sshd.service
# --------------------------------------------------------------------------

# --- Tailscale: uncomment every line down to the next ruler
# --------------------------------------------------------------------------
# pkg_install tailscale
# systemctl enable tailscaled.service
#
# ## Completions, on the same terms as section 6's installers: generated by the
# ## binary rather than checked in, into directories the "filesystem" package
# ## owns so they are there whether or not zsh and fish are.
# ##
# ## This replaces the "source <(tailscale completion bash)" line that upstream's
# ## help suggests for ~/.bashrc. A file here is loaded on demand by
# ## bash-completion, for every account, and does not depend on a shell rc that
# ## a user may have edited.
# tailscale completion bash > /usr/share/bash-completion/completions/tailscale
# tailscale completion zsh  > /usr/share/zsh/site-functions/_tailscale
# tailscale completion fish > /usr/share/fish/vendor_completions.d/tailscale.fish
# chmod 0644 /usr/share/bash-completion/completions/tailscale \
#            /usr/share/zsh/site-functions/_tailscale \
#            /usr/share/fish/vendor_completions.d/tailscale.fish
# --------------------------------------------------------------------------

# ## Trayscale is the tray icon for the daemon above, and it is a GTK4
# ## application: on a base with no desktop it drags in GTK and Mesa for about
# ## 840 MB - measured on quay.io/fedora/fedora-bootc:44, where tailscale alone
# ## costs 49 MB - and then never runs, because a base with no session never
# ## reads /etc/xdg/autostart. That is why it is a block of its own rather than a
# ## line in the one above. Leave it commented on a server.

# --- Trayscale, the tray icon for it - desktop bases only
# --------------------------------------------------------------------------
# pkg_install trayscale
# ## Trayscale is a tray icon, so it belongs to a desktop session rather than to
# ## systemd - "systemctl enable" has nothing to enable. A session reads
# ## /etc/xdg/autostart, which is the system-wide half of ~/.config/autostart and
# ## the only half a build can write: /home is a symlink into /var and is empty
# ## here, so there is no user directory to put anything in yet.
# ##
# ## /etc/skel would be the other option and is not used, because it only seeds
# ## accounts created after the image is installed. On a machine that upgrades in
# ## place, the accounts that matter already exist and would never see it.
# ##
# ## To switch it off for one account rather than for the image, drop a file of
# ## the same name into ~/.config/autostart containing "Hidden=true" - a user
# ## entry shadows the system one.
# install -d -m 0755 /etc/xdg/autostart
# cat > /etc/xdg/autostart/trayscale.desktop <<'DESKTOP'
# [Desktop Entry]
# Type=Application
# Name=Trayscale
# Icon=dev.deedles.Trayscale
# Exec=sh -c "sleep 5; exec trayscale --hide-window 2>/dev/null"
# Terminal=false
# X-GNOME-Autostart-enabled=true
# DESKTOP
# chmod 0644 /etc/xdg/autostart/trayscale.desktop
# --------------------------------------------------------------------------

# systemctl --global enable some-user-unit.service   # for every user session


#############################################################################
## 9. Optional: tweak configuration
#############################################################################
##
## Edit config files with sed, and keep a .bak so the change is obvious:
##
## Example: make firewalld default to the "drop" zone.
##
## firewalld reads /etc/firewalld/firewalld.conf, but on Fedora that is a symlink
## to one of the shipped presets (firewalld-standard.conf). Editing a preset the
## symlink does not point at - firewalld-workstation.conf, say - changes a file
## nothing reads and the default zone silently stays "public". Editing through
## the symlink with "sed -i" is no good either: that replaces the symlink with a
## regular file. Resolve it first, then edit the real target, then check the
## result - for a firewall setting a silent no-op is the worst outcome.

# --- firewalld default zone: uncomment every line to the next ruler
# --------------------------------------------------------------------------
# FIREWALLD_CONF="$(readlink -f /etc/firewalld/firewalld.conf)"
# cp "${FIREWALLD_CONF}" "${FIREWALLD_CONF}.bak"
# if grep -q '^DefaultZone=' "${FIREWALLD_CONF}"; then
#     sed -i 's/^DefaultZone=.*/DefaultZone=drop/' "${FIREWALLD_CONF}"
# else
#     echo 'DefaultZone=drop' >> "${FIREWALLD_CONF}"
# fi
# firewall-offline-cmd --get-default-zone | grep -qx drop
# --------------------------------------------------------------------------

## Example: require a YubiKey for sudo (pam_yubico is in rpm_packages already).
##
## PAM treats a missing "required" module as an authentication failure, so if
## pam_yubico.so is not actually in the image this line makes sudo impossible for
## every user - and "bootc container lint" will not catch it. Check the module is
## there and fail the build rather than shipping a system nobody can administer.
##
## You must also enrol a key (ykpamcfg -2) before booting the image, or sudo will
## reject you; /etc/pam.d/sudo.bak is left behind for recovery.

# --- YubiKey for sudo: uncomment every line down to the next ruler
# --------------------------------------------------------------------------
# if ! find /usr/lib64/security /usr/lib/security -name pam_yubico.so -print -quit 2>/dev/null | grep -q .; then
#     echo "ERROR: pam_yubico.so not found - refusing to edit /etc/pam.d/sudo." >&2
#     exit 1
# fi
# cp /etc/pam.d/sudo /etc/pam.d/sudo.bak
# sed -i '/PAM-1.0/a\auth       required     pam_yubico.so mode=challenge-response' /etc/pam.d/sudo
# --------------------------------------------------------------------------


#############################################################################
## 9a. Identify this image in /etc/os-release
#############################################################################
##
## os-release(5) is what hostnamectl, the desktop's About page, fastfetch, the
## bootloader entries and abrt read to decide what this machine is running.
## Untouched, it still says whatever the base says - "COSMIC Atomic", "CentOS
## Stream" - and points every support URL at that project, which is wrong twice
## over: this is not that image, and bug reports about it should not land in
## their tracker.
##
## Enabled by default - the values below are rewritten by set-image-name.sh,
## so after the rename in the Quick start they already point at your image
## and repository. Delete the section to keep the base's identity instead.
## Each field follows the convention it already uses:
##   VARIANT / VARIANT_ID   the edition on top of the distribution, so
##                          "COSMIC Atomic" / cosmic-atomic becomes
##                          "MYIMAGE Atomic" / myimage-atomic
##   VERSION / PRETTY_NAME  carry that same label while keeping the base's build
##                          number, so the version follows the base forward on
##                          its own rather than being hardcoded here
##   IMAGE_ID/IMAGE_VERSION os-release(5) reserves these for exactly this case, a
##                          system "prepared, built, shipped and updated as
##                          comprehensive, consistent OS images"
##   URLs, DEFAULT_HOSTNAME point at your repository instead of the base's
##
## Deliberately left alone: NAME, ID, VERSION_ID, CPE_NAME, LOGO, ANSI_COLOR.
## The distribution underneath really is Fedora (or CentOS) - every package comes
## from it, and vulnerability scanners match its advisories on CPE_NAME.
## Rewriting ID is what forces Universal Blue to patch grub2-switch-to-blscfg and
## /etc/system-release afterwards to undo the fallout; think twice before
## following them there.
##
## /etc/os-release is a symlink to ../usr/lib/os-release, and "sed -i" through a
## symlink replaces the symlink with a regular file, so resolve it first - the
## same trap as firewalld.conf above.

OS_RELEASE="$(readlink -f /etc/os-release)"
cp "${OS_RELEASE}" "${OS_RELEASE}.bak"

## Substitute a key if the base defines it, append it if not: VARIANT usually
## exists but IMAGE_ID does not, and a plain "sed -i" would silently do nothing
## for the second kind.

os_release_set() {
    if grep -q "^${1}=" "${OS_RELEASE}"; then
        sed -i "s|^${1}=.*|${1}=${2}|" "${OS_RELEASE}"
    else
        printf '%s=%s\n' "${1}" "${2}" >> "${OS_RELEASE}"
    fi
}

## A Fedora base's VERSION reads "44.20260819.0 (COSMIC Atomic)": keep the build
## number, drop its edition label. Read the values through a subshell so the
## sourced variables do not leak into the rest of this script.
##
## Every value is defaulted before use. This script runs under "set -u", so a
## base that does not set one of these would otherwise abort here with
## "VERSION: unbound variable" - and the VERSION_ID fallback on the next line,
## which exists for exactly that base, would never be reached.

OS_NAME="$(. "${OS_RELEASE}"; printf '%s' "${NAME:-}")"
OS_BUILD="$(. "${OS_RELEASE}"; printf '%s' "${VERSION:-}")"
OS_BUILD="${OS_BUILD%% *}"
[ -n "${OS_BUILD}" ] || OS_BUILD="$(. "${OS_RELEASE}"; printf '%s' "${VERSION_ID:-}")"

os_release_set VARIANT           "\"MYIMAGE Atomic\""
os_release_set VARIANT_ID        "myimage-atomic"
os_release_set VERSION           "\"${OS_BUILD} (MYIMAGE Atomic)\""
os_release_set PRETTY_NAME       "\"${OS_NAME} ${OS_BUILD} (MYIMAGE Atomic)\""
os_release_set DEFAULT_HOSTNAME  "\"myimage\""
os_release_set HOME_URL          "\"https://github.com/myorg/myimage\""
os_release_set DOCUMENTATION_URL "\"https://github.com/myorg/myimage\""
os_release_set SUPPORT_URL       "\"https://github.com/myorg/myimage/issues\""
os_release_set BUG_REPORT_URL    "\"https://github.com/myorg/myimage/issues\""
os_release_set IMAGE_ID          "myimage"
os_release_set IMAGE_VERSION     "\"${OS_BUILD}\""

## On a Fedora base, abrt uses these to file crashes against Fedora's Bugzilla.
## Nobody there can act on a crash in an image they did not build, so drop them.

sed -i '/^REDHAT_BUGZILLA_PRODUCT=/d
/^REDHAT_BUGZILLA_PRODUCT_VERSION=/d
/^REDHAT_SUPPORT_PRODUCT=/d
/^REDHAT_SUPPORT_PRODUCT_VERSION=/d' "${OS_RELEASE}"

## Prove the file still parses and that the edits landed. A malformed os-release
## breaks a great deal more than the About dialog, and an edit that quietly
## matched nothing is the failure mode this whole section is built to avoid.

( . "${OS_RELEASE}"
  [ "${VARIANT_ID:-}" = "myimage-atomic" ] || { echo "os-release: VARIANT_ID not applied" >&2; exit 1; }
  [ "${IMAGE_ID:-}" = "myimage" ]          || { echo "os-release: IMAGE_ID not applied" >&2; exit 1; }
  case "${PRETTY_NAME:-}" in
      *"MYIMAGE Atomic"*) ;;
      *) echo "os-release: PRETTY_NAME not applied" >&2; exit 1 ;;
  esac )

## NAME and the leading field of VERSION are left untouched, so the ISO name the
## workflow derives from them is unaffected.


#############################################################################
## 9b. Graphical boot
#############################################################################
##
## A splash screen instead of a wall of kernel messages needs two things, and a
## plain bootc base has neither:
##
##   1. plymouth in the image *and* in the initramfs. Desktop bases such as the
##      fedora-ostree-desktops ones ship both already; fedora-bootc ships
##      neither, and installing the package is not enough on its own - the
##      initramfs is prebuilt in the base and a layered package does not change
##      it, so it has to be regenerated here. (plymouth and
##      plymouth-system-theme are installed just below, for the same reason
##      section 8 installs its own: a rewritten rpm_packages must not be able
##      to take the splash screen with it.)
##   2. the "rhgb" kernel argument, which is what tells plymouth to draw
##      anything. That is shipped as
##      build_files/sysfiles/usr/lib/bootc/kargs.d/00-graphical-boot.toml and
##      applied by bootc when the image is installed or switched to; "bootc
##      container lint" parses the file, so a mistake in it fails the build.

pkg_install plymouth plymouth-system-theme

## A bootc image carries exactly one kernel, so this glob resolves to one entry.
KVER="$(basename /usr/lib/modules/*)"
INITRAMFS="/usr/lib/modules/${KVER}/initramfs.img"

## Regenerating a ~250 MB initramfs costs a couple of minutes of build time, so
## only do it when the base has not already done it for us. A base whose
## initramfs lsinitrd cannot read (it complains about the compression on some)
## simply gets regenerated - the safe direction to be wrong in.

if ! lsinitrd -m "${INITRAMFS}" 2>/dev/null | tr ' ' '\n' | grep -qx plymouth; then
    # --no-hostonly:  the image has to boot on any machine, not just the builder.
    # --add ostree:   the ostree module must be present or the system will not
    #                 boot at all. The bootc bases put it in their own dracut
    #                 config already; say it out loud rather than depend on that.
    # --reproducible: same input, same initramfs, so rebuilds do not churn layers.
    #
    # dracut prints "dracut-install: ERROR: installing '/root'" while it runs.
    # That comes from the base's own dracut configuration - it happens with or
    # without plymouth - and dracut still exits 0 and writes a working
    # initramfs. Not something this build introduced.
    dracut --force --no-hostonly --reproducible --zstd --kver "${KVER}" \
           --add ostree "${INITRAMFS}"
fi

## An initramfs without plymouth boots to a text console and nothing warns you,
## so check rather than hope. This one has to be able to read the file: it is the
## one dracut just wrote.
##
## The list is captured before it is searched rather than piped straight into
## grep. "grep -qx" exits at its first match and closes the pipe; lsinitrd and
## tr then die of SIGPIPE, and under "set -o pipefail" that becomes the status
## of the whole pipeline - so a successful match reads as a failed one. The
## list is small enough today that it is written before grep ever exits, which
## makes this luck rather than a guarantee.
##
## And say what went wrong. As a bare assertion this failed the build with no
## output at all: the last thing in the log was dracut's, and nothing anywhere
## named plymouth.

INITRAMFS_MODULES="$(lsinitrd -m "${INITRAMFS}" | tr ' ' '\n')"
if ! grep -qx plymouth <<<"${INITRAMFS_MODULES}"; then
    echo "ERROR: the initramfs at ${INITRAMFS} carries no plymouth module," >&2
    echo "so this image would boot to a text console rather than a splash" >&2
    echo "screen. dracut ran but did not pick plymouth up: check that plymouth" >&2
    echo "and plymouth-system-theme are installed. Both are in rpm_packages," >&2
    echo "and section 3 records any name the base's repositories do not carry" >&2
    echo "in /usr/share/image-build/skipped-packages." >&2
    exit 1
fi


#############################################################################
## 9c. Verify our own updates
#############################################################################
##
## Signed updates are on by default, which makes a signing key a
## prerequisite rather than an extra: the build needs your public key at
## build_files/cosign.pub, and the workflow needs the matching private half
## as the SIGNING_SECRET secret. Without them the build fails - deliberately
## and early, rather than publishing an image no machine can update to. The
## README's Signing section shows how to create the pair.
##
## The key is yours alone, so the template ships without one: a repository
## created from it fails its first build until you add yours. That is the
## intended greeting, not a bug - the check below says so in as many words.
##
## Signing alone would change nothing on the machine: "bootc upgrade" pulls
## unsigned images happily unless the system is told to check. That takes
## three things - the public key in the image, a registries.d entry telling
## containers/image to look for a sigstore attachment (shipped in sysfiles,
## inert on its own), and the policy.json rule below that turns "look" into
## "require".
##
## What this commits you to:
##  * Verification is MANDATORY for this repository. If signing ever breaks,
##    "bootc upgrade" refuses to install rather than accept an unverified
##    image - which is the point, but a broken signing step then blocks
##    updates until it is fixed.
##  * The signature must stay in the format containers/image can read -
##    build.yml pins cosign to the 2.x series for exactly that reason.
##
## TO BUILD WITHOUT SIGNATURE VERIFICATION, comment out two things together -
## either one alone leaves the system in a worse state than both:
##   1. every command in this section (the key check, the key install, the
##      policy.json merge, and the check that follows them);
##   2. the three cosign steps in .github/workflows/build.yml.
## Comment out only (1) and the workflow still demands a key it no longer
## needs; comment out only (2) and every machine keeps demanding a signature
## nothing produces, which blocks updates completely.

if [ ! -f "${CTX}/cosign.pub" ]; then
    echo "ERROR: build_files/cosign.pub is missing." >&2
    echo >&2
    echo "This image verifies its own updates, so it needs YOUR signing key -" >&2
    echo "the template ships without one on purpose. To add yours:" >&2
    echo >&2
    echo "  cosign generate-key-pair" >&2
    echo "  mv cosign.pub build_files/cosign.pub    # commit this" >&2
    echo "                                          # never commit cosign.key" >&2
    echo >&2
    echo "Then add the contents of cosign.key as a repository secret named" >&2
    echo "SIGNING_SECRET (Settings -> Secrets and variables -> Actions), so" >&2
    echo "the workflow can sign what this key verifies." >&2
    echo >&2
    echo "To build without signature verification instead, see the comment" >&2
    echo "above this check - two blocks have to go, not one." >&2
    exit 1
fi

## The repository the policy rule guards.
##
## A rule only applies to the repository it names. An image published
## somewhere else matches no rule at all, falls back to the base default
## "insecureAcceptAnything", and is then accepted unverified - silently, with
## nothing anywhere reporting a problem. So the repository is not written
## down here a second time: the workflow already passes the one it really
## publishes to as IMAGE_REPO, and the rule is scoped to that. Two values
## that must agree can drift apart; one value cannot.
##
## The literal is the fallback for local builds, which pass no IMAGE_REPO
## because no registry is involved. scripts/set-image-name.sh keeps it
## current, and "set-image-name.sh --check" - run by build.yml before
## anything else - fails the build if it is ever left stale.

POLICY_SCOPE="${IMAGE_REPO:-ghcr.io/myorg/myimage}"

## The key filename deliberately carries no project name. Nothing outside
## this section reads the path, so naming it after the image would only add
## one more literal to keep in step with a rename, for no gain.

POLICY_KEY="/etc/pki/containers/signing-key.pub"

install -Dm0644 "${CTX}/cosign.pub" "${POLICY_KEY}"

## The policy rule is only half the chain. containers/image does not look for
## a signature at all unless the repository is listed in
## /etc/containers/registries.d, and a listing that does not cover this image
## means the signature is never fetched - so the sigstoreSigned rule above
## fails every upgrade with "A signature was required, but no signature
## exists", on an image that was signed perfectly well.
##
## That listing ships as a plain file through sysfiles, so unlike the scope
## above it cannot follow IMAGE_REPO by itself. Check the two agree here,
## rather than let the machines find out. This is what catches a
## sigstore-attachments.yaml copied down from the template into a repository
## that was renamed long ago.
##
## containers/image matches these entries by namespace prefix, so a broader
## scope ("ghcr.io", or "ghcr.io/<owner>") is a legitimate choice and is
## accepted too.

ATTACH_FILE="/etc/containers/registries.d/sigstore-attachments.yaml"
ATTACH_SCOPE=""

if [ -f "${ATTACH_FILE}" ]; then
    ## The key is everything before the final colon on the line, not before
    ## the first: a registry may carry a port, and "registry.example.com:5000"
    ## is a perfectly ordinary scope. Stopping at the first colon found no key
    ## at all there, and the build then failed claiming nothing covered the
    ## repository while the entry sat in the file.
    for scope in $(sed -n 's/^[[:space:]]\{1,\}\([^[:space:]#].*\):[[:space:]]*$/\1/p' "${ATTACH_FILE}"); do
        case "${POLICY_SCOPE}" in
            "${scope}"|"${scope}"/*) ATTACH_SCOPE="${scope}"; break ;;
        esac
    done
fi

if [ -z "${ATTACH_SCOPE}" ]; then
    echo "ERROR: nothing in ${ATTACH_FILE}" >&2
    echo "covers the repository this image verifies:" >&2
    echo >&2
    echo "  policy scope : ${POLICY_SCOPE}" >&2
    echo >&2
    echo "Without a matching entry containers/image never fetches the" >&2
    echo "signature, and every 'bootc upgrade' fails with \"A signature was" >&2
    echo "required, but no signature exists\" - on a correctly signed image." >&2
    echo >&2
    echo "Line the two up with:" >&2
    echo >&2
    echo "  ./scripts/set-image-name.sh <image-name> <github-owner>" >&2
    echo >&2
    echo "which rewrites both, or edit the scope in" >&2
    echo "build_files/sysfiles/etc/containers/registries.d/sigstore-attachments.yaml" >&2
    echo "by hand." >&2
    echo >&2
    echo "Pass the owner as well: without it a rename changes the image half" >&2
    echo "and leaves the owner as it was, which lands you exactly here." >&2
    exit 1
fi

## policy.json already exists in the base image, so merge into it rather
## than ship a replacement through sysfiles - overwriting it wholesale would
## drop the defaults that let every other image still be pulled.
##
## Where it lives depends on the base. containers-common used to install it at
## /etc/containers/policy.json and now installs it at
## /usr/share/containers/policy.json instead - the move landed in 0.69. The
## reasoning is sound for an image-based system: /etc is machine-local state,
## merged with the machine's own edits on every update, and a default that
## belongs to the image has no business living there.
##
## Both layouts are in the field: a base carrying an older containers-common
## has the old path, a newer one the new path, and this template's Fedora and
## CentOS options between them cover both. So follow whichever the base
## actually ships rather than pick one - and note that /etc wins when a base
## somehow has both, which is the order containers/image itself looks in.
##
## Guessing wrong is not a loud failure: the merge would land in a file the
## running system never reads, every image would match no rule, and
## verification would be off with nothing anywhere saying so.
##
## python3 comes with every base this template lists; a base without it
## needs this merge rewritten (jq, or a shell-side edit).

POLICY_FILE=""

for candidate in /etc/containers/policy.json /usr/share/containers/policy.json; do
    if [ -f "${candidate}" ]; then
        POLICY_FILE="${candidate}"
        break
    fi
done

if [ -z "${POLICY_FILE}" ]; then
    echo "ERROR: this base image ships no policy.json." >&2
    echo >&2
    echo "Looked in:" >&2
    echo "  /etc/containers/policy.json" >&2
    echo "  /usr/share/containers/policy.json" >&2
    echo >&2
    echo "Signature verification is merged into the file the base provides, so" >&2
    echo "that the defaults letting every other image be pulled survive. With" >&2
    echo "no such file there is nothing to merge into - either the base does" >&2
    echo "not carry containers-common, or it has moved the file again. Add the" >&2
    echo "new location to the loop above." >&2
    exit 1
fi

POLICY_SCOPE="${POLICY_SCOPE}" POLICY_KEY="${POLICY_KEY}" POLICY_FILE="${POLICY_FILE}" python3 - <<'POLICY'
import json, os, pathlib
path = pathlib.Path(os.environ["POLICY_FILE"])
policy = json.loads(path.read_text())
policy.setdefault("transports", {}).setdefault("docker", {})[
    os.environ["POLICY_SCOPE"]
] = [
    {
        "type": "sigstoreSigned",
        "keyPath": os.environ["POLICY_KEY"],
        # A cosign signature carries only a repository, never a tag, so
        # matchRepository is the only identity check that can succeed.
        # The default (matchRepoDigestOrExact) rejects every signature.
        "signedIdentity": {"type": "matchRepository"},
    }
]
path.write_text(json.dumps(policy, indent=4) + "\n")
POLICY

## Prove the rule really landed, and that it points at a key that exists -
## a policy naming a keyPath the image does not carry fails at upgrade time
## on the machine, which is far too late to hear about it.

POLICY_SCOPE="${POLICY_SCOPE}" POLICY_KEY="${POLICY_KEY}" POLICY_FILE="${POLICY_FILE}" python3 -c '
import json, os, sys
policy = json.load(open(os.environ["POLICY_FILE"]))
scope, key = os.environ["POLICY_SCOPE"], os.environ["POLICY_KEY"]
rules = policy.get("transports", {}).get("docker", {}).get(scope)
if not rules:
    sys.exit("policy rule missing for %s" % scope)
if rules[0].get("keyPath") != key or not os.path.exists(key):
    sys.exit("policy key %s missing or not installed" % key)
'


#############################################################################
## 10. Directories that must exist at boot
#############################################################################
##
## /var is reset on every deployment, so a directory created during the build
## does not reach a freshly installed system - and "bootc container lint" warns
## about content in /var with no matching tmpfiles.d entry. Ship a rule that
## systemd-tmpfiles applies on every boot instead. This image already does, at
## build_files/sysfiles/usr/lib/tmpfiles.d/10-image-var-dirs.conf:
##
##   d /var/lib/plymouth 0755 root root -
##
## Add your own directories to that file rather than creating them here.
##
## Check before you write a rule, though: a well-packaged RPM brings its own.
## anacron's /var/spool/anacron, for instance, is already covered by
## /usr/lib/tmpfiles.d/cronie-anacron.conf from the cronie-anacron package.

## geoclue is the exception that cannot live in that file. It arrives as a
## dependency rather than a choice - xdg-desktop-portal pulls it in - and
## creates /var/lib/geoclue during the build, which lint then flags. The rule
## has to name geoclue's own user and group, and a tmpfiles rule naming a user
## that does not exist is not merely ignored: systemd-tmpfiles reports
## "Failed to resolve user" and exits non-zero, so the boot-time
## systemd-tmpfiles-setup unit ends up FAILED - the same red unit this image
## masks systemd-remount-fs to avoid. A base without geoclue would get exactly
## that from a statically shipped line, so write the rule here, where the
## build can see whether the user is actually there.

if getent passwd geoclue >/dev/null 2>&1; then
    printf 'd /var/lib/geoclue 0755 geoclue geoclue - -\n' \
        > /usr/lib/tmpfiles.d/20-geoclue-var-dir.conf
fi


#############################################################################
## 11. Build residue
#############################################################################
##
## /run is a tmpfs on a running system, so anything an RPM scriptlet left there
## during the build is dead weight in the image - and "bootc container lint"
## flags it. tuned's scriptlet creates /run/tuned; systemd-tmpfiles recreates it
## on every boot from the rule tuned itself ships, so dropping it here costs
## nothing.

rm -rf /run/tuned
