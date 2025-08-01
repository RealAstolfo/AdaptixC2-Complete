# AdaptixC2 Offline Build Configuration for Linux x86_64
# 
# This Nix file builds AdaptixC2 without requiring internet access during the build phase.
# All network resources are pre-fetched during the fetch phase, including Go 1.24.4.
#
# Target: Linux x86_64 only
#
# QUICK START:
# 1. Get Go hash:     nix-prefetch-url https://go.dev/dl/go1.24.4.linux-amd64.tar.gz
# 2. Get CSV hash:    nix-prefetch-url https://www.loldrivers.io/api/drivers.csv  
# 3. Replace hashes in this file (lines ~34 and ~62)
# 4. Build once:      nix-build AdaptixC2-Offline.nix (fails, shows vendor hash)
# 5. Replace vendor hash (line ~97)
# 6. Build again:     nix-build AdaptixC2-Offline.nix (succeeds!)
# 
# Usage: nix-build AdaptixC2-Offline.nix

let
  pkgs = import <nixpkgs> { };
  inherit (pkgs) stdenv;

  # Custom Go 1.24.4 installation for Linux x86_64
  # Get hash by running: nix-prefetch-url https://go.dev/dl/go1.24.4.linux-amd64.tar.gz
  go_1_24_4 = stdenv.mkDerivation rec {
    pname = "go";
    version = "1.24.4";
    
    # Fetch official Go binary release for Linux x86_64
    src = pkgs.fetchurl {
      url = "https://go.dev/dl/go${version}.linux-amd64.tar.gz";
      sha256 = "05w7z46p8633mbjq5grwhx0x1i0va7zbc624pbqsxbkjpcrxmrbp"; # Replace with correct hash
    };

    # No build needed for binary release
    dontBuild = true;
    dontConfigure = true;
    
    installPhase = ''
      mkdir -p $out
      cp -r * $out/
      
      # Ensure bin directory exists and create wrapper scripts that set GOROOT
      mkdir -p $out/bin-wrapped
      if [ -d "$out/bin" ]; then
        for tool in $out/bin/*; do
          if [ -f "$tool" ] && [ -x "$tool" ]; then
            toolname=$(basename "$tool")
            cat > "$out/bin-wrapped/$toolname" << EOF
#!/bin/bash
export GOROOT="$out"
export PATH="$out/bin:\$PATH"
exec "$tool" "\$@"
EOF
            chmod +x "$out/bin-wrapped/$toolname"
          fi
        done
      else
        echo "Warning: No bin directory found in Go distribution"
      fi
    '';
    
    # Set up the Go environment
    setupHook = pkgs.writeText "go-setup-hook" ''
      export GOROOT=@out@
      export PATH=@out@/bin-wrapped:$PATH
    '';
    
    passthru = {
      inherit version;
      isGo = true;
      GOOS = "linux";
      GOARCH = "amd64";
    };
    
    meta = with pkgs.lib; {
      description = "The Go Programming Language (version ${version}) for Linux x86_64";
      homepage = "https://golang.org/";
      license = licenses.bsd3;
      platforms = [ "x86_64-linux" ];
    };
  };
  
  vulnerableDriversList = pkgs.fetchurl {
    url = "https://www.loldrivers.io/api/drivers.csv";
    sha256 = "1zz97j1x807pwq5sk2lbhb3clkxk6yk71szr6bf7cmc0spra5f0f";
  };
  
  patchNetworkCalls = pkgs.writeShellScript "patch-network-calls" ''
    set -e
    
    echo "Patching Python scripts for offline build..."
    
    # Find and patch Python scripts that make network calls
    find . -name "*.py" -type f | while read -r pyfile; do
      if grep -q "urllib.request\|requests\|urlopen\|httpx\|aiohttp" "$pyfile" 2>/dev/null; then
        echo "Patching network calls in: $pyfile"
        
        # Backup original
        cp "$pyfile" "$pyfile.orig"
        
        # Patch common network libraries
        sed -i 's|urllib\.request\.urlopen.*|pass  # Patched for offline build|g' "$pyfile" || true
        sed -i 's|requests\.get.*|pass  # Patched for offline build|g' "$pyfile" || true
        sed -i 's|requests\.post.*|pass  # Patched for offline build|g' "$pyfile" || true
        
        # For the specific vulnerable drivers script
        if [[ "$pyfile" == *"download_vulnerable_driver_list.py" ]]; then
          # Completely replace the script
          cat > "$pyfile" << 'EOF'
#!/usr/bin/env python3
# Patched for offline Nix build
import os
import sys

def main():
    # Look for pre-provided CSV files
    possible_files = ["drivers.csv", "vulnerable_drivers.csv", "loldrivers.csv"]
    csv_file = None
    
    for filename in possible_files:
        if os.path.exists(filename):
            csv_file = filename
            break
    
    if csv_file:
        print(f"Using pre-fetched vulnerable drivers list: {csv_file}")
        # Copy/process the file as needed by the original script
        with open(csv_file, 'r') as f:
            content = f.read()
            print(f"Loaded {len(content.splitlines())} lines from drivers list")
    else:
        print("Warning: No vulnerable drivers list found, creating placeholder")
        with open("drivers.csv", 'w') as f:
            f.write("# Placeholder vulnerable drivers list for offline build\n")
            f.write("# In a real deployment, this should be updated with actual data\n")

if __name__ == "__main__":
    main()
EOF
        fi
      fi
    done
    
    echo "Network call patching complete"
  '';

  # Extension kit - handle Go dependencies if any
  extensionkit = stdenv.mkDerivation rec {
    pname = "adaptix-extensions";
    version = "1.0";
    src = pkgs.fetchzip {
      url = "https://github.com/Adaptix-Framework/Extension-Kit/archive/b2fe05d4700b47b08d65efc830335de79ceff3dd.tar.gz";
      sha256 = "01wrv7fal18i7qv8ws4lqvyj885pa4kklna7ar9wnymi2242b2ha";
    };
    
    nativeBuildInputs = with pkgs; [
      gnumake
      cmake
      pkg-config
      makeWrapper
      glibc.static
      pkgsCross.mingwW64.buildPackages.gcc
      pkgsCross.mingw32.buildPackages.gcc
      python3
      openssl
    ] ++ [ go_1_24_4 ]; # Use our custom Go 1.24.4
    
    buildInputs = with pkgs; [
      openssl
      cacert
    ];
    
    configurePhase = ''
      echo "Skipping configurePhase"
    '';
    
    buildPhase = ''
      # Disable Go module downloads
      export GOPROXY=off
      export GOSUMDB=off
      export GOCACHE=$TMPDIR/go-build-cache
      export GOPATH=$TMPDIR/go-path
      export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      export REQUESTS_CA_BUNDLE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      
      # Use our custom Go 1.24.4
      export GOROOT="${go_1_24_4}"
      export PATH="${go_1_24_4}/bin-wrapped:$PATH"
      
      echo "Using Go version: $(go version)"
      
      mkdir -p "$GOCACHE" "$GOPATH"
      
      # Provide pre-fetched data files
      echo "Setting up pre-fetched data files..."
      if [ -d "SAL-BOF/privcheck" ] || find . -name "*privcheck*" -type d 2>/dev/null | grep -q .; then
        # Find the privcheck directory wherever it is
        privcheck_dir=$(find . -name "*privcheck*" -type d | head -1)
        if [ -n "$privcheck_dir" ]; then
          cp ${vulnerableDriversList} "$privcheck_dir/drivers.csv"
          echo "Copied vulnerable drivers list to $privcheck_dir/drivers.csv"
        else
          echo "privcheck directory not found, creating SAL-BOF/privcheck/"
          mkdir -p SAL-BOF/privcheck
          cp ${vulnerableDriversList} SAL-BOF/privcheck/drivers.csv
        fi
      fi
      
      # Apply network call patches
      ${patchNetworkCalls}
      
      # Disable any other potential network calls
      export NO_NETWORK=1
      export OFFLINE_BUILD=1
      
      # Build each component
      for dir in */; do
        dirname=$(basename "$dir")
        if [ -d "$dir" ] && ([ -f "$dir/Makefile" ] || [ -f "$dir/makefile" ]); then
          echo "Building $dirname..."
          (cd "$dir" && make) || {
            echo "Initial build failed for $dirname, trying with offline flags..."
            (cd "$dir" && make OFFLINE=1 NO_NETWORK=1) || {
              echo "Warning: Failed to build $dirname, but continuing..."
              # Don't fail the entire build for one component
            }
          }
        elif [ -d "$dir" ]; then
          echo "Skipping $dirname (no Makefile)"
        fi
      done
      
      echo "Extension kit build phase completed"
    '';
    
    installPhase = ''
      mkdir -p $out/share
      cp -rvp AD-BOF $out/share/ || true
      cp -rvp Creds-BOF $out/share/ || true
      cp -rvp Elevation-BOF $out/share/ || true
      cp -rvp Execution-BOF $out/share/ || true
      cp -rvp Injection-BOF $out/share/ || true
      cp -rvp LateralMovement-BOF $out/share/ || true
      cp -rvp Postex-BOF $out/share/ || true
      cp -rvp Process-BOF $out/share/ || true
      cp -rvp SAL-BOF $out/share/ || true
      cp -rvp SAR-BOF $out/share/ || true
    '';
  };

  adaptixServer = pkgs.buildGoModule.override { go = go_1_24_4; } rec {
    pname = "adaptix-server";
    version = "0.7.0";
    
    src = pkgs.fetchzip {
      url = "https://github.com/Adaptix-Framework/AdaptixC2/archive/a2454af19f7a3ee18d5f47e5bd0dc720553f9026.tar.gz";
      sha256 = "19199nxbc5024wxajjfjm2yq1ncmw7vf6r8n0fzlq84n83k5f1j1";
    };
    
    sourceRoot = "source/AdaptixServer";
    
    vendorHash = "sha256-OA38UqImIin/qkqR1G0nYc4mdIUosykm8maUTm5J41A=";
        
    buildInputs = with pkgs; [
      openssl
    ];
    
    nativeBuildInputs = with pkgs; [
      pkg-config
    ];
    
    env.CGO_ENABLED = "1";
  };

  adaptixClient = stdenv.mkDerivation rec {
    pname = "adaptix-client";
    version = "0.7.0";
    
    src = pkgs.fetchzip {
      url = "https://github.com/Adaptix-Framework/AdaptixC2/archive/a2454af19f7a3ee18d5f47e5bd0dc720553f9026.tar.gz";
      sha256 = "19199nxbc5024wxajjfjm2yq1ncmw7vf6r8n0fzlq84n83k5f1j1";
    };
    
    nativeBuildInputs = with pkgs; [
      cmake
      pkg-config
      qt6.wrapQtAppsHook
    ];
    
    buildInputs = with pkgs; [
      qt6.qtbase
      qt6.qtwebsockets
      openssl
    ];
    
    # Build only the client
    sourceRoot = "source/AdaptixClient";
    
    configurePhase = ''
      runHook preConfigure
      # Patch cmake to use current directory
      cmake -B build .
      runHook postConfigure
    '';
    
    buildPhase = ''
      runHook preBuild
      cmake --build build
      runHook postBuild
    '';
    
    installPhase = ''
      runHook preInstall
      mkdir -p $out/bin
      cp build/AdaptixClient $out/bin/
      runHook postInstall
    '';
  };

  # Main adaptix package that combines everything
  adaptix = stdenv.mkDerivation rec {
    pname = "AdaptixC2";
    version = "0.7.0";
        
    nativeBuildInputs = with pkgs; [
      makeWrapper
      openssl
    ];

    # No actual building, just assembly
    dontBuild = true;
    dontConfigure = true;
    
    installPhase = ''
      mkdir -p $out/bin $out/share
      
      # Copy binaries
      cp ${adaptixServer}/bin/AdaptixServer $out/bin/AdaptixServer
      cp ${adaptixClient}/bin/AdaptixClient $out/bin/AdaptixClient
      
      # Generate certificates offline
      printf '\n\n\n\n\n\n\n' | ${pkgs.openssl}/bin/openssl req -x509 -nodes -newkey rsa:2048 -keyout server.rsa.key -out server.rsa.crt -days 3650
      mv server.rsa.key $out/share/
      mv server.rsa.crt $out/share/
      
      # Copy configuration files and patch paths
      substituteInPlace dist/profile.json \
        --replace-quiet "extenders/" "$out/share/extenders/" \
        --replace-quiet "404page.html" "$out/share/404page.html" \
        --replace-quiet "server.rsa.crt" "$out/share/server.rsa.crt" \
        --replace-quiet "server.rsa.key" "$out/share/server.rsa.key"
      cp dist/profile.json $out/share/
      cp -r dist/* $out/share/ || true
      
      # Copy extension kit
      if [ -d ${extensionkit}/share ]; then
        cp -r ${extensionkit}/share/* $out/share/
      fi
      
      chmod +x $out/bin/AdaptixServer $out/bin/AdaptixClient
    '';
  };

in adaptix