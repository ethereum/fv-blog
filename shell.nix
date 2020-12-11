let

  # git ls-remote https://github.com/NixOS/nixpkgs-channels.git nixos-unstable
  rev = "84d74ae9c9cbed73274b8e4e00be14688ffc93fe";

  pkgs = import (fetchTarball {
    url = "https://github.com/nixos/nixpkgs-channels/archive/${rev}.tar.gz";
    sha256 = "0ww70kl08rpcsxb9xdx8m48vz41dpss4hh3vvsmswll35l158x0v";
  }) {};

  gems = pkgs.bundlerEnv {
    name = "fv-blog-gems";
    gemdir = ./.;
  };

in pkgs.mkShell {
  buildInputs = with pkgs; [ bundix gems ];
}
