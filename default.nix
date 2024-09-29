{ lib
, buildGo122Module
, fetchFromGitHub
, fetchpatch
, buildEnv
, linkFarm
, overrideCC
, makeWrapper
, stdenv
, nixosTests

, pkgs
, cmake
, gcc12
, clblast
, libdrm
, rocmPackages
, cudaPackages
, linuxPackages
, darwin

, testers
, ollama

, config
  # one of `[ null false "rocm" "cuda" ]`
, acceleration ? null
}:

let
  pname = "ollama";
  # don't forget to invalidate all hashes each update
  version = "0.3.12";

  src = fetchFromGitHub {
    owner = "jmorganca";
    repo = "ollama";
    rev = "v${version}";
    hash = "sha256-K1FYXEP0bTZa8M+V4/SxI+Q+LWs2rsAMZ/ETJCaO7P8=";
    fetchSubmodules = true;
  };
  vendorHash = "sha256-hSxcREAujhvzHVNwnRTfhi0MKI3s8HNavER2VLz6SYk=";
  # ollama's patches of llama.cpp's example server
  # `ollama/llm/generate/gen_common.sh` -> "apply temporary patches until fix is upstream"
  # each update, these patches should be synchronized with the contents of `ollama/llm/patches/`
  llamacppPatches = [
    (preparePatch "0000-cmakelist.patch" "sha256-qIW45Js6WCTqDtC/uLyqKWjm7lgEc8ir12gq3pQJNbk=")
    (preparePatch "0001-load-progress.patch" "sha256-+KRcYqePmHMTPOmFaltlx87VQcC8Wsx4JbXmUK4mjpk=")
    (preparePatch "0003-load_exception.patch" "sha256-qL1Pv0Qt5mQ6rclL9qUo4y3GxqaM0SeojYHeS5k8zQE=")
    (preparePatch "0004-metal.patch" "sha256-XVeedBWp5rd0OUNo6cMO1tJaNlc3wWo0Xzha+GoMfbc=")
    (preparePatch "0005-default-pretokenizer.patch" "sha256-mxqHnDbiy8yfKFUYryNTj/xay/lx9KDiZAiekFSkxr8=")
    (preparePatch "0006-embeddings.patch" "sha256-vjMuXHZYZ99ZSIKChcaq5fvci2wmgz10sN7yIfJN96Y=")
    (preparePatch "0007-clip-unicode.patch" "sha256-LYy4LniBwjBRNs11tYoPwjZNTQY87plr55HxmsX1alc=")
    (preparePatch "0008-solar-pro.patch" "sha256-VwY6l2BvuT73Hvp1UrH3ALNQZn8ENEZbOhNvEzvkMP8=")
  ];

  preparePatch = patch: hash: fetchpatch {
    url = "file://${src}/llm/patches/${patch}";
    inherit hash;
    stripLen = 1;
    extraPrefix = "llm/llama.cpp/";
  };


  accelIsValid = builtins.elem acceleration [ null false "rocm" "cuda" ];
  validateFallback = lib.warnIf (config.rocmSupport && config.cudaSupport)
    (lib.concatStrings [
      "both `nixpkgs.config.rocmSupport` and `nixpkgs.config.cudaSupport` are enabled, "
      "but they are mutually exclusive; falling back to cpu"
    ])
    (!(config.rocmSupport && config.cudaSupport));
  validateLinux = api: (lib.warnIfNot stdenv.isLinux
    "building ollama with `${api}` is only supported on linux; falling back to cpu"
    stdenv.isLinux);
  shouldEnable = assert accelIsValid;
    mode: fallback:
      ((acceleration == mode)
      || (fallback && acceleration == null && validateFallback))
      && (validateLinux mode);

  enableRocm = shouldEnable "rocm" config.rocmSupport;
  enableCuda = shouldEnable "cuda" config.cudaSupport;


  rocmLibs = [
    rocmPackages.clr
    rocmPackages.hipblas
    rocmPackages.rocblas
    rocmPackages.rocsolver
    rocmPackages.rocsparse
    rocmPackages.rocm-device-libs
    rocmPackages.rocm-smi
  ];
  rocmClang = linkFarm "rocm-clang" {
    llvm = rocmPackages.llvm.clang;
  };
  rocmPath = buildEnv {
    name = "rocm-path";
    paths = rocmLibs ++ [ rocmClang ];
  };

  cudaToolkit = buildEnv {
    name = "cuda-toolkit";
    ignoreCollisions = true; # FIXME: find a cleaner way to do this without ignoring collisions
    paths = [
      cudaPackages.cudatoolkit
      cudaPackages.cuda_cudart
      cudaPackages.cuda_cudart.static
    ];
  };

  runtimeLibs = lib.optionals enableRocm [
    rocmPath
  ] ++ lib.optionals enableCuda [
    linuxPackages.nvidia_x11
  ];

  appleFrameworks = darwin.apple_sdk_11_0.frameworks;
  metalFrameworks = [
    appleFrameworks.Accelerate
    appleFrameworks.Metal
    appleFrameworks.MetalKit
    appleFrameworks.MetalPerformanceShaders
  ];


  goBuild =
    if enableCuda then
      buildGo122Module.override { stdenv = overrideCC stdenv gcc12; }
    else
      buildGo122Module;
  inherit (lib) licenses platforms maintainers;
in
goBuild ((lib.optionalAttrs enableRocm {
  ROCM_PATH = rocmPath;
  CLBlast_DIR = "${clblast}/lib/cmake/CLBlast";
}) // (lib.optionalAttrs enableCuda {
  CUDA_LIB_DIR = "${cudaToolkit}/lib";
  CUDACXX = "${cudaToolkit}/bin/nvcc";
  CUDAToolkit_ROOT = cudaToolkit;
}) // {
  inherit pname version src vendorHash;

  nativeBuildInputs = [
    cmake
  ] ++ lib.optionals enableRocm [
    rocmPackages.llvm.bintools
  ] ++ lib.optionals (enableRocm || enableCuda) [
    makeWrapper
  ] ++ lib.optionals stdenv.isDarwin
    metalFrameworks;

  buildInputs = lib.optionals enableRocm
    (rocmLibs ++ [ libdrm ])
  ++ lib.optionals enableCuda [
    cudaPackages.cuda_cudart
  ] ++ lib.optionals stdenv.isDarwin
    metalFrameworks;

  patches = [
    # disable uses of `git` in the `go generate` script
    # ollama's build script assumes the source is a git repo, but nix removes the git directory
    # this also disables necessary patches contained in `ollama/llm/patches/`
    # those patches are added to `llamacppPatches`, and reapplied here in the patch phase
    ./disable-git.patch
    # disable a check that unnecessarily exits compilation during rocm builds
    # since `rocmPath` is in `LD_LIBRARY_PATH`, ollama uses rocm correctly
    # ./disable-lib-check.patch
  ]
  ++ llamacppPatches
  ;
  postPatch = ''
    # replace inaccurate version number with actual release version
    substituteInPlace version/version.go --replace-fail 0.0.0 '${version}'
  '';
  preBuild = ''
    # disable uses of `git`, since nix removes the git directory
    export OLLAMA_SKIP_PATCHING=true
    # build llama.cpp libraries for ollama
    go generate ./...
  '';
  postFixup = ''
    # the app doesn't appear functional at the moment, so hide it
    mv "$out/bin/app" "$out/bin/.ollama-app"
  '' + lib.optionalString (enableRocm || enableCuda) ''
    # expose runtime libraries necessary to use the gpu
    mv "$out/bin/ollama" "$out/bin/.ollama-unwrapped"
    makeWrapper "$out/bin/.ollama-unwrapped" "$out/bin/ollama" ${
      lib.optionalString enableRocm
        ''--set-default HIP_PATH '${rocmPath}' ''} \
      --suffix LD_LIBRARY_PATH : '/run/opengl-driver/lib:${lib.makeLibraryPath runtimeLibs}'
  '';

  ldflags = [
    "-s"
    "-w"
    "-X=github.com/jmorganca/ollama/version.Version=${version}"
    "-X=github.com/jmorganca/ollama/server.mode=release"
  ];

  passthru.tests = {
    service = nixosTests.ollama;
    rocm = pkgs.ollama.override { acceleration = "rocm"; };
    cuda = pkgs.ollama.override { acceleration = "cuda"; };
    version = testers.testVersion {
      inherit version;
      package = ollama;
    };
  };

  meta = {
    description = "Get up and running with large language models locally";
    homepage = "https://github.com/ollama/ollama";
    changelog = "https://github.com/ollama/ollama/releases/tag/v${version}";
    license = licenses.mit;
    platforms = platforms.unix;
    mainProgram = "ollama";
    maintainers = with maintainers; [ abysssol dit7ya elohmeier ];
  };
})
