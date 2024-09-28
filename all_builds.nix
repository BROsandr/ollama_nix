{ sources ? import ./nix/sources.nix }:
let
  pkgs = import <nixpkgs> { config = {}; overlays = []; };
  defaultBuild = pkgs.callPackage ./. { };

  shell = pkgs.mkShell {
    inputsFrom = [ defaultBuild ];
    packages = with pkgs; [
      defaultBuild
    ];

    hardeningDisable = ["all"];
  };
in
{
  inherit defaultBuild shell;
}
