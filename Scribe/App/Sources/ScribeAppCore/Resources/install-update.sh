#!/bin/bash
# Arguments are passed directly by Process; no release data is evaluated as code.
set -u
parent_pid="$1"
staging="$2"
candidate="$3"
destination="$4"
requirement="$5"
backup="$staging/Previous Scribe.app"

notify_failure() {
    /usr/bin/osascript -e 'display alert "Scribe update could not be installed" message "Your previous application has been preserved. If Scribe did not reopen, open it from Applications. Please try the update again." as critical' >/dev/null 2>&1 || true
}

# Never replace a bundle while capture is still finalizing. A cancelled or
# stalled quit leaves the original app untouched.
for ((attempt = 0; attempt < 300; attempt++)); do
    kill -0 "$parent_pid" 2>/dev/null || break
    /bin/sleep 1
done
if kill -0 "$parent_pid" 2>/dev/null; then
    /bin/rm -rf "$staging"
    notify_failure
    exit 1
fi

# Revalidate immediately before installation, including nested shipped helpers.
if ! /usr/bin/codesign --verify --deep --strict -R "$requirement" "$candidate" ||
   ! /usr/sbin/spctl --assess --type execute "$candidate"; then
    /usr/bin/open "$destination" || true
    /bin/rm -rf "$staging"
    notify_failure
    exit 1
fi

if ! /bin/mv "$destination" "$backup"; then
    /usr/bin/open "$destination" || true
    /bin/rm -rf "$staging"
    notify_failure
    exit 1
fi
if [[ ! -e "$destination" && ! -L "$destination" ]] && /bin/mv "$candidate" "$destination"; then
    if /usr/bin/open "$destination"; then
        /bin/rm -rf "$staging"
        exit 0
    fi
    # Preserve the rejected replacement before restoring the previous version.
    /bin/mv "$destination" "$candidate" || { notify_failure; exit 1; }
fi
if [[ ! -e "$destination" && ! -L "$destination" ]] && /bin/mv "$backup" "$destination"; then
    /usr/bin/open "$destination" || true
    /bin/rm -rf "$staging"
fi
# If restoration itself fails, keep the backup in staging for recovery.
notify_failure
exit 1
