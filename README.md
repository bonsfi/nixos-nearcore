Deploying NEAR Using NixOS / NixOps
================================================================================

NixOS is a declarative operating system that allows describing your deployment
in terms of a purely functional declarative language named [Nix][]. There are
some great reasons to use Nix / NixOps:

- Infrastructure as Code: Same properties to Terraform.
- Declarative Infrastructure: Unlike Terraform, we can describe systems also.
- Instant Rollbacks: NixOS can revert the software setup of any setup instantly.
- Automated Tests: NEAR is automatically tested during the package build. More on this below.

With all these properties, we can create a CI/CD pipeline that is robust, secure,
testable, and completely version controlled. The single biggest benefit here is
unlike Terraform setups, we can test and manage our entire deployed software
stack as well.

--------------------------------------------------------------------------------

Before we get started you will need two files, a Nix expression and a patch, in 
order to build **neard** through nix. Save the following two files as `near.nix`
and `gitpatch.patch` respectively:

### near.nix

This nix expression will build **neard** using the correct rust nightly, the
build is as deterministic (if neard is buildable as a reproducible build then
the following nix expression will give you a guaranteed binary!).

**NOTE**: This will test neard, if neard fails to pass its own unit/integration
tests then the build will fail, and nixos will automatically prevent deployment!

```nix
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
```

### gitfix.patch

You'll also need the following patch, which disables neard's git versioning. You
need this because the above nix expression does not compile within a git clone
of the repo and NEAR does not yet handle this gracefully.

```patch
diff --git a/neard/src/main.rs b/neard/src/main.rs
index ab380ef8..595b585d 100644
--- a/neard/src/main.rs
+++ b/neard/src/main.rs
@@ -65,8 +65,7 @@ fn main() {
     openssl_probe::init_ssl_cert_env_vars();

     let default_home = get_default_home();
-    let version =
-        Version { version: crate_version!().to_string(), build: git_version!().to_string() };
+    let version = Version { version: crate_version!().to_string(), build: "00000000".to_string() };
     let matches = App::new("NEAR Protocol Node")
         .setting(AppSettings::SubcommandRequiredElseHelp)
         .version(format!("{} (build {})", version.version, version.build).as_str())
diff --git a/test-utils/loadtester/src/main.rs b/test-utils/loadtester/src/main.rs
index f3a560bd..70d66073 100644
--- a/test-utils/loadtester/src/main.rs
+++ b/test-utils/loadtester/src/main.rs
@@ -42,8 +42,7 @@ fn configure_logging(log_level: log::LevelFilter) {
 }

 fn main() {
-    let version =
-        Version { version: crate_version!().to_string(), build: git_version!().to_string() };
+    let version = Version { version: crate_version!().to_string(), build: "00000000".to_string() };
     let default_home = get_default_home();

     let matches = App::new("NEAR Protocol loadtester")
```

Once you have these two files saved as `near.nix` and `gitfix.patch` 
respectively we can start preparing an automated CI pipeline on top of nixops.

# CI/CD: A NixOps 101

If you already know NixOps, you can skip this section (and probably the guide
if you only came for the nix expression above). If not, here's a quick primer
on getting setup:

### 1. Create Deployment

First we'll need a NixOps deployment file for NEAR, to do this we create a new
file named `default.nix`. For this guide, we'll create an AWS instance to house
our NEAR server. For this, you will need to have configured an AWS Keypair on
the machine you are deploying from, you can do this through authenticating with
the aws CLI, a guide for that [can be found here](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-quickstart.html).

Once setup, update the `accessKeyId` below to the section name listed inside
your `~/.aws/credentials` file.

```nix
{ region      ? "us-west-2"
, accessKeyId ? "dev"
}
let
backend = { config, region, ... }:
{
    environment.systemPackages = [ ./near.nix ];
    deployment.targetEnv = "ec2";
    deployment.ec2.accessKeyId = accessKeyId;
    deployment.ec2.instanceType = "m1.small";
    deployment.ec2.region = region;
};

in
{
  network.description = "NEAR Deployment";
  backend0 = backend { inherit region; zone = "${region}a"; };
}
```

With our initial NixOps expression at hand, let's create and deploy our new Nix
deployment:

```
nixops create -d near near.nix 
nixops deploy -d near
```

As long as your AWS environment (or other configured environment) are correct
the above should build and deploy neard to a server. Though it won't run it
yet. First we'll want to setup a CI pipeline for these nix deployments.

### 2. Nix Deployment Pipeline with Github Actions

To deploy this automatically, we'll want to take all the above files and stick
them in a github repo. Once you've done this, we can setup a Github action to
automate this deployment.

Before continuing, make sure any secrets you need to use are available to the
CI pipeline. In this example we are utilizing AWS, so we need to provide some
AWS keys in scope. GitHub secrets allows us to do this securely, and can be
done by going to **Repo -> Settings -> Secrets**. For example:

![](assets/images/2020-10-02-06-55-19.png)

With our secrets ready, let's setup a new basic pipeline. We can use a script to
setup and prepare nixops for deployment. Here's our initial Github Action 
template to get started with:

```yml
name: NixOps Deploy

on:
  push:
    branches: [ master ]

jobs:
  build:
    runs-on: ubuntu-latest
    
    steps:
    - uses: actions/checkout@v2

    # We'll utilize a bash script to setup nixops, this gives us more control
    # over the action as there are varying quality of NixOps actions out there.
    - shell: bash
      env:
        AWS_CLI_DATA: ${{ secrets.AWS_CLI_DATA }}
      run: |
        # Setup Nix + NixOps
        sudo mkdir /nix
        sh <(curl -L https://nixos.org/nix/install) --no-daemon
        . $HOME/.profile
        nix-env -iA nixops awscli
        mkdir -p $HOME/.aws/credentials
        echo "$AWS_CLI_DATA" > $HOME/.aws/credentials

        # We'll use a slight hack here, in order to get started, rather than
        # find a way to persist NixOps state (which is a good idea but a step
        # further than this guide), we'll trust nix to rebuild its state through
        # a fix operation, and make any changes required.
        nixops deploy --check -d near
```

[Nix]: https://nixos.org
