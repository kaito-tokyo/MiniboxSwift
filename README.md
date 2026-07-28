# minibox-swift

## macOS setup companion

`minibox-view` can display a local HTML checklist beside the VM. Supplying the
HTML is optional; without `--html-path`, the VM window behaves as before.

From a repository checkout:

```sh
minibox-view \
  --bundle-path=/path/to/image.miniboxvm \
  --html-path=Setup-macOS-Runner.html
```

After `make install`, the included checklist is installed at
`/usr/local/share/minibox/Setup-macOS-Runner.html` by default. The HTML owns its
content and interactions; Minibox does not track checklist state, completion,
output, or resume progress.

The guest finalizer source is installed at
`/usr/local/share/minibox/minibox-finalize-macos`. Set `MINIBOX_SHARE_DIR` when
shared files are installed under a different prefix.

`minibox prepare --variant=macos` displays that installed checklist during its
manual setup step. Use `--html-path=PATH` to select another companion, or set
`MINIBOX_SHARE_DIR` when shared files are installed under another prefix.

After Setup Assistant finishes, the injected `minibox-finalize-macos` startup
service detects the runner GUI session (or `/var/db/.AppleSetupDone` on systems
that create it), then waits for the operator to enable Remote Login. Once
`com.openssh.sshd` is active, it applies the remaining non-interactive runner
settings, verifies them, and shuts down from inside the guest. Progress and
errors are written to `/var/log/minibox-finalize.log`; a failed verification
leaves the guest running for serial-console diagnosis.
