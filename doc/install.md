# Installing ezu

[Documentation](README.md) › Installing ezu

ezu is one static binary of about 2 MB for macOS and Linux, with no runtime dependencies. Install it with Homebrew, download it, or build it; the [library](library.md) installs with luarocks.

## Homebrew

```sh
brew install mpenet/tap/ezu
```

On macOS or Linux, from ezu's own tap. The formula installs the release binary below, plus bash, zsh and fish completion; `brew upgrade` follows new releases.

## Debian, Ubuntu, Fedora, RHEL

Each release has packages of the Linux binaries, with bash, zsh and fish completion, from the [releases page](https://github.com/mpenet/ezu/releases):

```sh
sudo apt install ./ezu_1.0.0~beta8_amd64.deb        # Debian, Ubuntu (arm64 too)
sudo dnf install ./ezu-1.0.0~beta8-1.x86_64.rpm     # Fedora, RHEL (aarch64 too)
```

They come from no package repository, so updates are installed the same way; a pre-release like `1.0.0-beta8` is versioned `1.0.0~beta8`, which sorts before `1.0.0`.

## Standalone binary

Download the binary for your platform from the [releases page](https://github.com/mpenet/ezu/releases) (`ezu-macos-arm64`, `ezu-macos-x86_64`, `ezu-linux-x86_64` or `ezu-linux-arm64`), then install it:

```sh
install -m 755 ezu-macos-arm64 /usr/local/bin/ezu
```

Each release lists the files' SHA-256 sums in `SHA256SUMS` and carries a [build provenance attestation](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations) proving the binary was built by this repository's release workflow:

```sh
shasum -a 256 -c SHA256SUMS --ignore-missing
gh attestation verify ezu-macos-arm64 --repo mpenet/ezu
```

The binary embeds Lua, luasocket, libcurl, mbedTLS and libyaml (`ezu --licenses` lists them all with their licenses). The macOS binaries run on macOS 12 or later; the Linux binaries are fully static (built against musl), so they run on any distribution, old or new. HTTPS needs the system's CA certificates (the `ca-certificates` package on minimal Linux images); see [TLS and proxies](tls.md).

## From source

```sh
# fennel, lunajson, luasocket, lyaml, busted
make deps
# produces bin/ezu-bin
make binary
# runs it with Lua's module paths emptied, and checks it links only system libraries
make check-binary
# installs bin/ezu-bin as /usr/local/bin/ezu (PREFIX=... and DESTDIR=... to change)
make install
```

Building needs a C compiler, `lua` (5.4 or later) and `luarocks`, `fennel`, `libyaml`, `pkg-config`, `unzip` and `curl`: the build downloads the mbedTLS and libcurl sources, checks them against pinned checksums and links them in statically.

## With luarocks

Installs `ezu` as a Lua script, together with the [library](library.md):

```sh
luarocks install ezu
```

luarocks installs the Lua dependencies (lunajson, luasocket, lyaml) and compiles the libcurl binding, which needs the libcurl headers (`libcurl4-openssl-dev` on Debian and Ubuntu, `libcurl-devel` on Fedora; macOS ships them) and the libyaml headers. From a checkout: `luarocks make ezu-dev-1.rockspec`.

## Shell completion

```sh
# fish
ezu completion fish > ~/.config/fish/completions/ezu.fish

# bash, in ~/.bashrc (works with the bash 3.2 of macOS)
eval "$(ezu completion bash)"

# zsh, in ~/.zshrc after compinit
eval "$(ezu completion zsh)"
```

Completion offers commands, profile names, operations (fish also shows their summaries), the declared query parameters and headers after `--q.` and `--h.`, the body's properties after `--b.`, server variables after `--server.`, allowed values after `NAME=`, workflow documents, workflows and their inputs (`NAME=`), and the options of the current command. Specs come from the schema cache, so completion doesn't wait for the network once a spec has been used.
