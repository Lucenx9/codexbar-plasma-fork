# CodexBar Plasma Widget

Experimental KDE Plasma 6 frontend for CodexBar.

This applet follows the same split as the macOS app: CodexBarCore and
CodexBarCLI own provider logic, authentication, config, and JSON payloads. The
Plasma widget only renders local CLI output.

## Requirements

- KDE Plasma 6
- `kpackagetool6`
- `org.kde.plasma.plasma5support`
- `codexbar` CLI on `PATH`, or an absolute CLI path configured in the widget

Install the CLI from the main CodexBar release tarballs, Homebrew formula, AUR
package, or a local Swift build.

## Install

From this directory:

```sh
kpackagetool6 -t Plasma/Applet -i .
```

For development updates:

```sh
kpackagetool6 -t Plasma/Applet -u .
```

Then add **CodexBar** to a Plasma panel.

## CLI Check

Before debugging the widget, verify the data source directly:

```sh
codexbar usage --format json --json-only
codexbar usage --format json --json-only --provider codex --source oauth
```

If Plasma does not inherit your shell `PATH`, set an absolute command path in
the widget settings.

## Structure

```text
platforms/kde/plasmoid/
  metadata.json
  contents/config/
  contents/ui/
```

Provider support stays in the upstream Swift CLI. Add fields to the CLI JSON
contract first when the Plasma frontend needs more data.
