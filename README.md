# baa 🐏

*a tiny ram for your RAM*

<img src="icon/icon_1024.png" width="128">

tldr; baa lives in your menu bar, tells you when your mac is about to run out of RAM or disk, finds the stuff quietly eating it, and frees it in one click.

<img src="docs/demo.gif" width="560" alt="baa: open the menu bar panel, shear the leftovers, RAM goes from 9% to 63% free">

if you like **baa**, i’d love a star ⭐️😄

## why

turns out most of my RAM wasn't going to apps i had open. it was mostly dev servers, builds and agent leftovers i'd forgotten about.

**baa** 🐏 is a little ram that headbutts all of that out of your mac. it plays a tiny baa when it frees something (you can mute this if you hate whimsy though :P)

## what it does

- lives in your menu bar as 🐏 + how much RAM is free. turns 🟡 / 🟠 / 🔴 when things are getting tight
- finds stuff you forgot was still running:
  - 👻 apps and scripts that should've closed but didn't
  - 🤖 things ai agents started and forgot about
  - 💤 big stuff just sitting there idle (agent sessions idle for hours, docker with no containers, an ollama model still loaded)
- tells you how much RAM you'd get back, and frees it in one click
- pings you a few minutes before you run out
- also finds dev junk filling up your disk (old builds, package caches etc.) and trashes it in one click


## install

```sh
brew tap selviarora/baa https://github.com/selviarora/baa
brew install selviarora/baa/baa
brew services start baa
```

that builds baa on your mac, starts it in your menu bar (and at every login), and adds the `baa` command. needs macOS 14+.

<details>
<summary>or build it yourself</summary>

you'll need xcode command line tools (`xcode-select --install`).

```sh
git clone https://github.com/selviarora/baa && cd baa
./install.sh
```

that builds the app into `~/Applications`, starts it when you log in, and adds the `baa` command.
</details>

## commands

| | |
|---|---|
| `baa` | RAM readout + leftovers, right in your terminal |
| `baa free <id>` | free one leftover (ids are in the readout) |
| `baa free all` | free everything it found |
| `baa disk` | dev junk taking up your disk |
| `baa disk clean <id>` | clear one (or `all`) |
| `baa warn 20 10` | go 🟡 at 20% free and 🔴 at 10% (or tap the sliders icon in the panel) |
| `baa test` | send a sample notification |

## warning levels

by default baa goes 🟡 at 15% RAM free and 🔴 at 8%. to change that, click 🐏 → the sliders icon at the bottom → set your own. or from the terminal:

```sh
baa warn 20 10   # 🟡 at 20% free, 🔴 at 10%
baa warn         # see what it's set to
```

it'll still go 🔴 if macOS itself says memory is critical.

the 🟠 "dropping fast" heads-up only fires when RAM keeps sliding and you're close to 🟡, not on every app launch. turn it off in the same place, or with `baa warn --no-trend`.

## how it decides what's a leftover

basically baa looks for stuff that's still running but not doing anything:

- its app or terminal is closed but it's still going
- an ai agent started it and it's been sitting idle for 15+ min
- it's big and hasn't used any cpu in a while

it also watches memory pressure (the green / yellow / red graph in activity monitor), not just how much RAM is used. macs use most of their RAM all the time and that's usually ok!

it will also never kill anything on its own.

## update

```sh
brew upgrade baa
```

or if you built it yourself: `git pull && ./install.sh`

## uninstall

if you used brew:

```sh
brew services stop baa && brew uninstall baa
```

if you built it yourself:

```sh
launchctl bootout gui/$(id -u)/com.selvi.baa
rm -rf ~/Applications/Baa.app ~/Library/LaunchAgents/com.selvi.baa.plist ~/.local/bin/baa
```

vibecoded this in 30 mins so hopefully nothing is broken!
