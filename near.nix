{ clang
, callPackage
, git
, fetchFromGitHub
, llvm
, llvmPackages
, openssl
, perl
, pkgconfig
, makeRustPlatform
, stdenv
, zlib
, ... }:

# Initialize a Mozilla Rust-Overlayed Nightly
let
mozillaOverlay = fetchFromGitHub {
    owner  = "mozilla";
    repo   = "nixpkgs-mozilla";
    rev    = "9f35c4b09fd44a77227e79ff0c1b4b6a69dff533";
    sha256 = "18h0nvh55b5an4gmlgfbvwbyqj91bklf1zymis6lbdh75571qaz0";
};

# Build Custom rustPlatform
mozilla      = callPackage "${mozillaOverlay.out}/package-set.nix" {};
rustNightly  = (mozilla.rustChannelOf { date = "2020-05-15"; channel = "nightly"; }).rust;
rustFixed    = rustNightly // { meta.platforms = stdenv.lib.platforms.all; };
rustPlatform = makeRustPlatform { cargo = rustFixed; rustc = rustFixed; };

in
rustPlatform.buildRustPackage rec {
    pname             = "nearcore";
    version           = "1.13.1";
    cargoSha256       = "03j9hpmdpjv0lcb25ld3sm4046qwwddw8zhg7yl2cjmbpcclf6g3";
    cargoBuildFlags   = [ "-p" "neard" ];
    doCheck           = false;
    patches           = [ ./gitfix.patch ];
    nativeBuildInputs = [ perl pkgconfig llvm clang git ];
    buildInputs       = [ clang openssl.dev zlib ];

    LIBCLANG_PATH     = "${llvmPackages.libclang}/lib";
    CARGO_PKG_VERSION = version;

    src = fetchFromGitHub {
        owner  = "nearprotocol";
        repo   = "nearcore";
        rev    = "1384bcdeadce766f833298d71981749fcda941c8";
        sha256 = "1gyx1c6hk7xa11nvb0biglk7kx72c1lq72iw9983ilsl75bwxr9c";
    };
}
