#!/usr/bin/env bash
set -euxo pipefail

# --- Base deps (noninteractive to avoid tzdialog etc)
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  git curl ca-certificates unzip build-essential autoconf automake \
  libncurses5-dev libssl-dev libwxgtk3.0-gtk3-dev libgl1-mesa-dev \
  libglu1-mesa-dev libpng-dev libssh-dev unixodbc-dev

# --- Install/Update asdf
if [ ! -d "$HOME/.asdf" ]; then
  git clone https://github.com/asdf-vm/asdf.git "$HOME/.asdf" --branch v0.14.0
fi

# Ensure asdf is available for this script and future shells
. "$HOME/.asdf/asdf.sh"
grep -q 'asdf.sh' "$HOME/.bashrc" || echo '. $HOME/.asdf/asdf.sh' >> "$HOME/.bashrc"
grep -q 'asdf.bash' "$HOME/.bashrc" || echo '. $HOME/.asdf/completions/asdf.bash' >> "$HOME/.bashrc"

# --- Plugins
asdf plugin add erlang https://github.com/asdf-vm/asdf-erlang.git || true
asdf plugin add elixir https://github.com/asdf-vm/asdf-elixir.git || true
asdf plugin update --all

# --- Pin exact versions (OTP 27!)
ERLANG_VER="27.1.2"
ELIXIR_VER="1.17.3"

# Write .tool-versions so `asdf install` is reproducible
# (If you keep a .tool-versions in the repo, you can skip these echos.)
{
  echo "erlang ${ERLANG_VER}"
  echo "elixir ${ELIXIR_VER}"
} > "$PWD/.tool-versions"

# --- Clean any bad/corrupt Elixir downloads from previous runs
rm -rf "$HOME/.asdf/downloads/elixir/${ELIXIR_VER%-otp-*}" || true

# --- Install & set globals
asdf install erlang "${ERLANG_VER}"
asdf install elixir "${ELIXIR_VER}"
asdf global erlang "${ERLANG_VER}"
asdf global elixir "${ELIXIR_VER}"
asdf reshim

# --- Verify
erl -noshell -eval 'io:format("OTP=~s~n",[erlang:system_info(otp_release)]), halt().' -s
elixir -v
