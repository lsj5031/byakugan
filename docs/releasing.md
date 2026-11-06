# Windows preview releases

The first binary is a preview, not a stable-release claim. Public visibility
and the license for Byakugan's original source require the owner's decision.
Third-party licenses remain separate. Do not switch visibility until the
source/history/media disclosure review is accepted.

## Build and verify

Use Windows x64, Python 3.11+, Git and Zig **0.17.1**. Follow the README's pinned
nanoui checkout and patch steps in a clean pair of sibling directories. Commit
the source first so every archive names its exact Git commit.

```powershell
python -X utf8 tools/package_release.py
```

The packager refuses a dirty app checkout or a different nanoui base. Use a
fresh dependency checkout with only the included patch; the reverse-apply check
verifies the patch is present but does not certify unrelated dependency edits.
It runs formatting and all tests with **ReleaseSafe**, a baseline x64 CPU and
`x86_64-windows-gnu`, then builds stripped GUI and CLI binaries. It checks PE
architecture, subsystem, ASLR/NX and system DLL imports, and runs the packaged
binaries from a separate staging directory.

The smoke checks exercise CLI help/version/demo/invalid arguments, an ordinary
folder scan with independently known totals, and invisible native chooser,
light/dark demo and folder-scan captures. They never trigger UAC, open Explorer,
write the system clipboard or recycle files. They do not replace a manual
cleanup and privilege-transition test on a disposable Windows installation.

Output is under `artifacts/release/`: a versioned ZIP, `.zip.sha256`, a public
build manifest, and separate evidence logs/captures. Existing ZIPs are not
overwritten; pass `--output` with a new directory for another attempt. Only the
two executables, quick-start text, build manifest and dependency notices enter
the ZIP. PDBs, screenshots, logs, source paths and demo music are not packaged.

## Automated checks

The Windows workflow runs the same packager on pushes to main and pull requests.
It pins action revisions, the nanoui commit, and the Zig archive SHA-256 from
the official download index. Job permissions are read-only. It uploads ZIPs
and checksums as workflow artifacts; it does not publish releases or change
repository visibility.

## Publish deliberately

Create a draft prerelease for `v` plus the manifest version, targeted at the
verified commit, and upload the ZIP, checksum and build manifest. Download the
uploaded ZIP and compare its checksum before handing it off. Keep validation
limitations and unsigned-binary status in the release notes.

Before a stable release, validate real recycling/restoration, cancellation and
partial failures, ordinary/elevated/alternate-account handoffs and the oldest
Windows version claimed as supported. Signing needs an owner-controlled
certificate; checksums establish file integrity, not publisher identity.
