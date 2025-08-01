# AdaptixC2 Offline Build with Relocatable Zip Package
# 
# This builds AdaptixC2 using the original build method (make all) and creates a relocatable zip
# The zip can be extracted and run on other Linux x86_64 systems
#
# HASHES TO REPLACE:
# 1. Go 1.24.4 hash: nix-prefetch-url https://go.dev/dl/go1.24.4.linux-amd64.tar.gz
# 2. Drivers.csv hash: Automatically handled by CI or manual prefetch  
# 3. Agent beacon vendor hash: Run build, copy hash from error message
#
# Usage: nix-build AdaptixC2-Offline.nix
# Result: Creates both the normal build AND a zip file in result/

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
      sha256 = "sha256-d+XaM7tyrq7xukQYtv5RG8TQQYc8v4LlqmMYdA35hxc=";
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
      # Required attributes for buildGoModule
      GOOS = "linux";
      GOARCH = "amd64";
      CGO_ENABLED = "1";
    };
    
    meta = with pkgs.lib; {
      description = "The Go Programming Language (version ${version}) for Linux x86_64";
      homepage = "https://golang.org/";
      license = licenses.bsd3;
      platforms = [ "x86_64-linux" ];
    };
  };

  # Pre-fetch the vulnerable drivers CSV that SAL-BOF tries to download during build
  vulnerableDriversList = pkgs.fetchurl {
    url = "https://www.loldrivers.io/api/drivers.csv";
    sha256 = "1zz97j1x807pwq5sk2lbhb3clkxk6yk71szr6bf7cmc0spra5f0f"; # Replace with correct hash
  };

  # Create a script to handle offline builds by patching network calls
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

  adaptixServerVendor = pkgs.buildGoModule.override { go = go_1_24_4; } rec {
    pname = "adaptix-server-vendor";
    version = "0.7.0";
    
    src = pkgs.fetchzip {
      url = "https://github.com/Adaptix-Framework/AdaptixC2/archive/a2454af19f7a3ee18d5f47e5bd0dc720553f9026.tar.gz";
      sha256 = "19199nxbc5024wxajjfjm2yq1ncmw7vf6r8n0fzlq84n83k5f1j1";
    };

    sourceRoot = "source/AdaptixServer";
    vendorHash = "sha256-OA38UqImIin/qkqR1G0nYc4mdIUosykm8maUTm5J41A=";

    env.CGO_ENABLED = "1";

    # We only want the vendor directory, not to actually build
    buildPhase = ''
      echo "Vendoring complete for agent_beacon"
    '';
    
    installPhase = ''
      mkdir -p $out
      cp -r vendor $out/ || echo "No vendor directory found"
      cp go.mod $out/ || true
      cp go.sum $out/ || true
      echo "Vendored agent_beacon dependencies" > $out/vendor-info.txt
    '';    
  };

  # Vendor Go modules for agent_beacon specifically
  agentBeaconVendor = pkgs.buildGoModule.override { go = go_1_24_4; } rec {
    pname = "adaptix-agent-beacon-vendor";
    version = "0.7.0";
    
    src = pkgs.fetchzip {
      url = "https://github.com/Adaptix-Framework/AdaptixC2/archive/a2454af19f7a3ee18d5f47e5bd0dc720553f9026.tar.gz";
      sha256 = "19199nxbc5024wxajjfjm2yq1ncmw7vf6r8n0fzlq84n83k5f1j1";
    };
    
    sourceRoot = "source/Extenders/agent_beacon";
    
    # Vendor hash for agent_beacon - replace with correct hash from build error
    # To get this hash: run the build, it will fail showing the correct hash
    vendorHash = "sha256-E4TcNkYFgFKULVYGPaY63exLrZAeWSf3qI2h8Et3iq4=";
    
    env.CGO_ENABLED = "1";
    
    # We only want the vendor directory, not to actually build
    buildPhase = ''
      echo "Vendoring complete for agent_beacon"
    '';
    
    installPhase = ''
      mkdir -p $out
      cp -r vendor $out/ || echo "No vendor directory found"
      cp go.mod $out/ || true
      cp go.sum $out/ || true
      echo "Vendored agent_beacon dependencies" > $out/vendor-info.txt
    '';
  };

  # Vendor Go modules for agent_gopher specifically
  agentGopherVendor = pkgs.buildGoModule.override { go = go_1_24_4; } rec {
    pname = "adaptix-agent-gopher-vendor";
    version = "0.7.0";
    
    src = pkgs.fetchzip {
      url = "https://github.com/Adaptix-Framework/AdaptixC2/archive/a2454af19f7a3ee18d5f47e5bd0dc720553f9026.tar.gz";
      sha256 = "19199nxbc5024wxajjfjm2yq1ncmw7vf6r8n0fzlq84n83k5f1j1";
    };
    
    sourceRoot = "source/Extenders/agent_gopher";
    
    # Vendor hash for agent_gopher - replace with correct hash from build error
    # To get this hash: run the build, it will fail showing the correct hash
    vendorHash = "sha256-k+zJYJMmsjcwu0bOLLXAe06w2BAfPIMN/58IglrUetg=";
    
    env.CGO_ENABLED = "1";
    
    # We only want the vendor directory, not to actually build
    buildPhase = ''
      echo "Vendoring complete for agent_gopher"
    '';
    
    installPhase = ''
      mkdir -p $out
      cp -r vendor $out/ || echo "No vendor directory found"
      cp go.mod $out/ || true
      cp go.sum $out/ || true
      echo "Vendored agent_gopher dependencies" > $out/vendor-info.txt
    '';
  };

  # Vendor Go modules for listener_beacon_http specifically
  listenerBeaconHTTPVendor = pkgs.buildGoModule.override { go = go_1_24_4; } rec {
    pname = "adaptix-listener-beacon-http-vendor";
    version = "0.7.0";
    
    src = pkgs.fetchzip {
      url = "https://github.com/Adaptix-Framework/AdaptixC2/archive/a2454af19f7a3ee18d5f47e5bd0dc720553f9026.tar.gz";
      sha256 = "19199nxbc5024wxajjfjm2yq1ncmw7vf6r8n0fzlq84n83k5f1j1";
    };
    
    sourceRoot = "source/Extenders/listener_beacon_http";

    vendorHash = "sha256-67AX3MMfUHIdDBk2ODKvaFAnQs5P93IfjHmaKckLXNg=";
    
    env.CGO_ENABLED = "1";
    
    # We only want the vendor directory, not to actually build
    buildPhase = ''
      echo "Vendoring complete for listener_beacon_http"
    '';
    
    installPhase = ''
      mkdir -p $out
      cp -r vendor $out/ || echo "No vendor directory found"
      cp go.mod $out/ || true
      cp go.sum $out/ || true
      echo "Vendored listener_beacon_http dependencies" > $out/vendor-info.txt
    '';
  };

  # Vendor Go modules for listener_beacon_smb specifically
  listenerBeaconSMBVendor = pkgs.buildGoModule.override { go = go_1_24_4; } rec {
    pname = "adaptix-listener-beacon-smb-vendor";
    version = "0.7.0";
    
    src = pkgs.fetchzip {
      url = "https://github.com/Adaptix-Framework/AdaptixC2/archive/a2454af19f7a3ee18d5f47e5bd0dc720553f9026.tar.gz";
      sha256 = "19199nxbc5024wxajjfjm2yq1ncmw7vf6r8n0fzlq84n83k5f1j1";
    };
    
    sourceRoot = "source/Extenders/listener_beacon_smb";
    
    vendorHash = "sha256-xf25iOaj9YKhucEkj92xX0oFdaqDWdIipSTGXGZd0pM=";
    
    env.CGO_ENABLED = "1";
    
    # We only want the vendor directory, not to actually build
    buildPhase = ''
      echo "Vendoring complete for listener_beacon_smb"
    '';
    
    installPhase = ''
      mkdir -p $out
      cp -r vendor $out/ || echo "No vendor directory found"
      cp go.mod $out/ || true
      cp go.sum $out/ || true
      echo "Vendored listener_beacon_smb dependencies" > $out/vendor-info.txt
    '';
  };

  # Vendor Go modules for listener_beacon_tcp specifically
  listenerBeaconTCPVendor = pkgs.buildGoModule.override { go = go_1_24_4; } rec {
    pname = "adaptix-listener-beacon-tcp-vendor";
    version = "0.7.0";
    
    src = pkgs.fetchzip {
      url = "https://github.com/Adaptix-Framework/AdaptixC2/archive/a2454af19f7a3ee18d5f47e5bd0dc720553f9026.tar.gz";
      sha256 = "19199nxbc5024wxajjfjm2yq1ncmw7vf6r8n0fzlq84n83k5f1j1";
    };
    
    sourceRoot = "source/Extenders/listener_beacon_tcp";
    
    vendorHash = "sha256-xf25iOaj9YKhucEkj92xX0oFdaqDWdIipSTGXGZd0pM=";
    
    env.CGO_ENABLED = "1";
    
    # We only want the vendor directory, not to actually build
    buildPhase = ''
      echo "Vendoring complete for listener_beacon_tcp"
    '';
    
    installPhase = ''
      mkdir -p $out
      cp -r vendor $out/ || echo "No vendor directory found"
      cp go.mod $out/ || true
      cp go.sum $out/ || true
      echo "Vendored listener_beacon_tcp dependencies" > $out/vendor-info.txt
    '';
  };


  # Vendor Go modules for listener_gopher_tcp specifically
  listenerGopherTCPVendor = pkgs.buildGoModule.override { go = go_1_24_4; } rec {
    pname = "adaptix-listener-gopher-tcp-vendor";
    version = "0.7.0";
    
    src = pkgs.fetchzip {
      url = "https://github.com/Adaptix-Framework/AdaptixC2/archive/a2454af19f7a3ee18d5f47e5bd0dc720553f9026.tar.gz";
      sha256 = "19199nxbc5024wxajjfjm2yq1ncmw7vf6r8n0fzlq84n83k5f1j1";
    };
    
    sourceRoot = "source/Extenders/listener_gopher_tcp";
    
    vendorHash = "sha256-eU4gcNEworCXqUjLb9qLkrnFRS0TXfttKkUTJntkUcQ=";
    
    env.CGO_ENABLED = "1";
    
    # We only want the vendor directory, not to actually build
    buildPhase = ''
      echo "Vendoring complete for listener_gopher_tcp"
    '';
    
    installPhase = ''
      mkdir -p $out
      cp -r vendor $out/ || echo "No vendor directory found"
      cp go.mod $out/ || true
      cp go.sum $out/ || true
      echo "Vendored listener_gopher_tcp dependencies" > $out/vendor-info.txt
    '';
  };
  
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
      
      
      # Build each component
      for dir in */; do
        dirname=$(basename "$dir")
        if [ -d "$dir" ] && ([ -f "$dir/Makefile" ] || [ -f "$dir/makefile" ]); then
          echo "Building $dirname..."
          (cd "$dir" && make)
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

  # Main adaptix package that builds both server and client together like the original
  adaptix = stdenv.mkDerivation rec {
    pname = "AdaptixC2";
    version = "0.7.0";
    src = pkgs.fetchzip {
      url = "https://github.com/Adaptix-Framework/AdaptixC2/archive/a2454af19f7a3ee18d5f47e5bd0dc720553f9026.tar.gz";
      sha256 = "19199nxbc5024wxajjfjm2yq1ncmw7vf6r8n0fzlq84n83k5f1j1";
    };
    
    nativeBuildInputs = [
      pkgs.gnumake
      pkgs.cmake
      pkgs.pkg-config
      pkgs.makeWrapper
    ];
    
    buildInputs = [
      extensionkit
      pkgs.pkgsCross.mingwW64.buildPackages.gcc
      pkgs.pkgsCross.mingw32.buildPackages.gcc
      go_1_24_4
      pkgs.openssl
      pkgs.qt6.qtbase
      pkgs.qt6.qtwebsockets
    ];
    
    dontWrapQtApps = true;
    
    configurePhase = ''
      runHook preConfigure
      runHook postConfigure
    '';
    
    buildPhase = ''
      runHook preBuild
      echo "Patching AdaptixClient/Makefile to fix cmake source directory..."
      if [ -f AdaptixClient/Makefile ]; then
        sed -i 's/cmake ..$/cmake ./g' AdaptixClient/Makefile
      fi
      
      echo "Setting Go environment variables..."
      export GOCACHE=$TMPDIR/go-build-cache
      export GOPATH=$TMPDIR/go-path
      export GOROOT="${go_1_24_4}"
      export PATH="${go_1_24_4}/bin-wrapped:$PATH"
      export GOPROXY=off
      export GOSUMDB=off
      mkdir -p "$GOCACHE" "$GOPATH"

      if [ -d "AdaptixServer" ] && [ -d "${adaptixServerVendor}/vendor" ]; then
        echo "Copying vendor for agent_beacon"
        cp -r ${adaptixServerVendor}/vendor AdaptixServer/
        cp ${adaptixServerVendor}/go.mod AdaptixServer/ || true
        cp ${adaptixServerVendor}/go.sum AdaptixServer/ || true
      fi


      echo "Setting up vendored Go modules for Extenders..."
      if [ -d "Extenders/agent_beacon" ] && [ -d "${agentBeaconVendor}/vendor" ]; then
        echo "Copying vendor for agent_beacon"
        cp -r ${agentBeaconVendor}/vendor Extenders/agent_beacon/
        cp ${agentBeaconVendor}/go.mod Extenders/agent_beacon/ || true
        cp ${agentBeaconVendor}/go.sum Extenders/agent_beacon/ || true
      fi

      if [ -d "Extenders/agent_gopher" ] && [ -d "${agentGopherVendor}/vendor" ]; then
        echo "Copying vendor for agent_gopher"
        cp -r ${agentGopherVendor}/vendor Extenders/agent_gopher/
        cp ${agentGopherVendor}/go.mod Extenders/agent_gopher/ || true
        cp ${agentGopherVendor}/go.sum Extenders/agent_gopher/ || true
      fi

      if [ -d "Extenders/listener_beacon_http" ] && [ -d "${listenerBeaconHTTPVendor}/vendor" ]; then
        echo "Copying vendor for listener_beacon_http"
        cp -r ${listenerBeaconHTTPVendor}/vendor Extenders/listener_beacon_http/
        cp ${listenerBeaconHTTPVendor}/go.mod Extenders/listener_beacon_http/ || true
        cp ${listenerBeaconHTTPVendor}/go.sum Extenders/listener_beacon_http/ || true
      fi

      if [ -d "Extenders/listener_beacon_smb" ] && [ -d "${listenerBeaconSMBVendor}/vendor" ]; then
        echo "Copying vendor for listener_beacon_smb"
        cp -r ${listenerBeaconSMBVendor}/vendor Extenders/listener_beacon_smb/
        cp ${listenerBeaconSMBVendor}/go.mod Extenders/listener_beacon_smb/ || true
        cp ${listenerBeaconSMBVendor}/go.sum Extenders/listener_beacon_smb/ || true
      fi
      
      if [ -d "Extenders/listener_beacon_tcp" ] && [ -d "${listenerBeaconTCPVendor}/vendor" ]; then
        echo "Copying vendor for listener_beacon_tcp"
        cp -r ${listenerBeaconTCPVendor}/vendor Extenders/listener_beacon_tcp/
        cp ${listenerBeaconTCPVendor}/go.mod Extenders/listener_beacon_tcp/ || true
        cp ${listenerBeaconTCPVendor}/go.sum Extenders/listener_beacon_tcp/ || true
      fi
      
      if [ -d "Extenders/listener_gopher_tcp" ] && [ -d "${listenerGopherTCPVendor}/vendor" ]; then
        echo "Copying vendor for listener_gopher_tcp"
        cp -r ${listenerGopherTCPVendor}/vendor Extenders/listener_gopher_tcp/
        cp ${listenerGopherTCPVendor}/go.mod Extenders/listener_gopher_tcp/ || true
        cp ${listenerGopherTCPVendor}/go.sum Extenders/listener_gopher_tcp/ || true
      fi      

      echo "Running make all..."
      substituteInPlace Makefile --replace-warn "sudo setcap" "echo skipping setcap"
      make all || { echo "Makefile build failed!"; exit 1; }
    '';
    
    installPhase = ''
      mkdir -p $out/bin
      mkdir -p $out/share
      mv dist/adaptixserver $out/bin/AdaptixServer
      mv dist/AdaptixClient $out/bin/AdaptixClient
      printf '\n\n\n\n\n\n\n' | openssl req -x509 -nodes -newkey rsa:2048 -keyout server.rsa.key -out server.rsa.crt -days 3650
      mv server.rsa.key $out/share/
      mv server.rsa.crt $out/share/
      substituteInPlace dist/profile.json --replace-quiet "extenders/" "$out/share/extenders/"
      substituteInPlace dist/profile.json --replace-quiet "404page.html" "$out/share/404page.html"
      substituteInPlace dist/profile.json --replace-quiet "server.rsa.crt" "$out/share/server.rsa.crt"
      substituteInPlace dist/profile.json --replace-quiet "server.rsa.key" "$out/share/server.rsa.key"
      mv dist/* $out/share/
      chmod +x $out/bin/AdaptixServer $out/bin/AdaptixClient
    '';
  };

in
# Create both the normal build AND a relocatable zip package
pkgs.stdenv.mkDerivation {
  name = "AdaptixC2-Complete";
  version = "0.7.0";
  
  nativeBuildInputs = with pkgs; [ zip ];
  
  # No source needed, we're packaging the built result
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;
  
  installPhase = ''
    mkdir -p $out/bin $out/share
    
    # Copy the normal build result
    cp -r ${adaptix}/bin/* $out/bin/
    cp -r ${adaptix}/share/* $out/share/
    cp -r ${extensionkit}/share/* $out/share/
    
    # Create relocatable package directory
    mkdir -p package/AdaptixC2
    cd package/AdaptixC2
    
    # Copy binaries to package
    mkdir -p bin share
    cp ${adaptix}/bin/* bin/
    cp -r ${adaptix}/share/* share/
    
    # Create README
    cat > README.txt << 'EOF'
AdaptixC2 Relocatable Package
=============================

Quick Start:
-----------
./bin/AdaptixServer     # Start the server
./bin/AdaptixClient     # Start the client

Files:
------
bin/AdaptixServer       # Server binary
bin/AdaptixClient       # Client binary
share/                  # Configuration files, certificates, extensions
README.txt              # This file
EOF
    
    # Create the packages
    cd ..
    zip -r AdaptixC2-relocatable.zip AdaptixC2/ >/dev/null
    
    # Copy packages to output
    cp AdaptixC2-relocatable.zip $out/
    
    echo "Build complete. Created:"
    echo "- Normal Nix result in bin/ and share/"
    echo "- Relocatable packages:"
    ls -la $out/*.zip
  '';
  
  meta = with pkgs.lib; {
    description = "AdaptixC2 with relocatable package";
    platforms = [ "x86_64-linux" ];
  };
}