# Contributing to FolderLock

Thanks for wanting to help! 🎉 Every contribution counts: code, translations, bug reports, docs, design, or just telling us what confused you.

## Getting set up

You only need macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`). You don't need the full Xcode.

```bash
git clone https://github.com/alidiab2/FolderLock.git
cd FolderLock
./build.sh        # builds, signs, installs to /Applications and restarts Finder
```

## Project layout

| File | Purpose |
| --- | --- |
| `main.swift` | The app: vault engine (`Vault`), SwiftUI windows (`LockView`, `HomeView`), background logic (`Controller`) |
| `FinderSync.swift` | Finder Sync extension: context menu and "folder opened" events |
| `Info.plist`, `FinderSync-Info.plist`, `FinderSync.entitlements` | Bundle metadata and the extension's sandbox rules |
| `build.sh` | Build, sign and install script |
| `docs/` | Images for the README |

## Testing safely

**Always test on a throwaway folder**, never on real files. The vault engine has a headless mode that's handy for this:

```bash
B=/Applications/FolderLock.app/Contents/MacOS/FolderLock
mkdir -p /tmp/fl-test && echo hello > /tmp/fl-test/a.txt
FOLDERLOCK_PASSWORD=test $B --lock   /tmp/fl-test
FOLDERLOCK_PASSWORD=test $B --unlock /tmp/fl-test
```

If you change the Finder extension, check that it's running with:

```bash
pluginkit -m -i local.folderlock.app.findersync   # "+" means enabled
```

## Pull requests

1. Fork the repo and create a branch (`git checkout -b my-feature`).
2. Keep changes focused. One feature or fix per PR is easiest to review.
3. Match the existing style: small functions, short comments that say *why*, plain SwiftUI.
4. In the PR, describe what you changed and how you tested it. Screenshots are great for UI changes.

Not sure where to start? Pick anything from the **"Help make it better"** list in the README, or open an issue to talk it through first.

## Using AI to contribute

This project was built with AI ([Claude Code](https://claude.com/claude-code)), and you're welcome to use AI tools too. Just make sure you understand and have tested what you submit, especially anything that touches encryption or deletes files.

## Be kind

Be respectful and patient, and assume good intent. Everyone here started as a beginner at something.
