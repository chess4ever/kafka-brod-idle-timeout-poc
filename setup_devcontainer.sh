#!/usr/bin/env bash
set -e

# Installa dipendenze di base
sudo apt-get update
sudo apt-get install -y git curl automake autoconf libncurses5-dev libssl-dev libwxgtk3.0-gtk3-dev libgl1-mesa-dev libglu1-mesa-dev libpng-dev libssh-dev unixodbc-dev

# Installa asdf
git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.0

# Configura la shell
echo '. $HOME/.asdf/asdf.sh' >> ~/.bashrc
echo '. $HOME/.asdf/completions/asdf.bash' >> ~/.bashrc

# Carica asdf nella sessione corrente
. $HOME/.asdf/asdf.sh

# Installa Erlang ed Elixir
asdf plugin add erlang https://github.com/asdf-vm/asdf-erlang.git
asdf install erlang 27.1.2
asdf global erlang 27.1.2

asdf plugin add elixir https://github.com/asdf-vm/asdf-elixir.git
asdf install elixir 1.17.3
asdf global elixir 1.17.3