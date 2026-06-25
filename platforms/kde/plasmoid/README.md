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

On Arch-compatible systems:

```sh
yay -S codexbar-cli
```

## Install

From the repository root:

```sh
kpackagetool6 -t Plasma/Applet -i platforms/kde/plasmoid
```

From this directory, the equivalent command is:

```sh
kpackagetool6 -t Plasma/Applet -i .
```

## Upgrade

For development updates from the repository root:

```sh
kpackagetool6 -t Plasma/Applet -u platforms/kde/plasmoid
systemctl --user restart plasma-plasmashell.service
```

From this directory, the equivalent applet update command is:

```sh
kpackagetool6 -t Plasma/Applet -u .
```

Then add **CodexBar** to a Plasma panel.

## CLI Check

Before debugging the widget, verify the data source directly:

```sh
codexbar usage --format json --json-only
codexbar usage --format json --json-only --provider codex --source oauth
codexbar usage --provider codex --all-accounts --format json --json-only
```

If Plasma does not inherit your shell `PATH`, set an absolute command path in
the widget settings.

## Display Options

The General settings page exposes the panel Display mode:

- Percent: show the selected provider meter as a percentage.
- Pace: show the current pace marker when the provider reports one.
- Percent and pace: show both compactly.
- Reset time: show the selected provider reset label instead of the percentage.

Reset labels can be shown as countdowns or absolute local clock times.

## Structure

```text
platforms/kde/plasmoid/
  metadata.json
  contents/config/
  contents/ui/
```

Provider support stays in the upstream Swift CLI. Add fields to the CLI JSON
contract first when the Plasma frontend needs more data.
