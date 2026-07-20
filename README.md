<h1 align="center">
  <img src="https://raw.githubusercontent.com/JappeOS/JappeOS/dev/Icons/jappeos-logo-banner-white-512.png" width="120"><br>
  appsupport_launcher_windows
</h1>

<p align="center">
  <strong>Adds Windows application support to JappeOS.</strong>
</p>

<p align="center">
  <a href="./issues"><img src="https://img.shields.io/github/issues/JappeOS/appsupport_launcher_windows?style=plastic&color=edda09"></a>
  <a href="./pulls"><img src="https://img.shields.io/github/issues-pr/JappeOS/appsupport_launcher_windows?style=plastic&color=40a842"></a>
  <a href="./blob/main/LICENSE"><img src="https://img.shields.io/github/license/JappeOS/appsupport_launcher_windows?style=plastic&color=9d09ed"></a>
  <img src="https://img.shields.io/badge/arch-x86__64-blue?style=plastic">
  <img src="https://img.shields.io/badge/status-experimental-orange?style=plastic">
  <a href="https://discord.gg/dRtU4HR"><img src="https://img.shields.io/discord/716673375946407972?style=plastic&color=3250a8"></a>
</p>

---

## Overview

Adds Windows application support to JappeOS, supporting multiple Wine/Proton runtimes. Written in Dart.

## Features

* Launch *.exe
* Multiple runtimes
* Multiple prefixes
* Runtime auto-updates from sources
* Use protonfixes where possible
* Desktop entry creation with icon extraction

## Role in the OS

An unofficial system compatibility tool that allows the user to run Microsoft Windows programs easily.

## Building

### Prerequisites

- Dart SDK

### Setup

Clone the repository and fetch dependencies:
```bash
$ git clone https://github.com/JappeOS/appsupport_launcher_windows.git
$ cd appsupport_launcher_windows
$ dart pub get
```

### Build

#### Linux

```bash
$ ./build.sh
```

This produces a binary in:
```
tmp/
```

Run locally:
```bash
$ ./tmp/appsupport_launcher_windows "/path/to/app.exe"
```

#### Other platforms

This program currently only works on Linux.

#### Troubleshooting

If the build fails after dependency changes:
```bash
$ dart pub get
```

## Contributing

Contributions of all kinds are welcome and appreciated. You can help the project by:

- ⭐ Starring the repository to show your support
- 💖 Sponsoring the project (if available)
- 🐞 Reporting bugs via [GitHub Issues](./issues)
- 💡 Requesting or discussing new features

For code contributions, please see [`CONTRIBUTING.md`](./CONTRIBUTING.md) for guidelines.

## License

This repository is part of the JappeOS project and is licensed under the terms described in the [`LICENSE`](./LICENSE) file.