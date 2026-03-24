{
  description = "PostgreSQL development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      inherit (pkgs) lib;
      isLinux = pkgs.stdenv.hostPlatform.isLinux;

      mkPostgresql =
        {
          gssapi ? false,
          icu ? true,
          ldap ? false,
          libcurl ? false,
          libnuma ? false,
          liburing ? false,
          libxml ? true,
          libxslt ? true,
          llvm ? false,
          lz4 ? true,
          nls ? false,
          openssl ? true,
          pam ? false,
          plperl ? false,
          plpython ? false,
          pltcl ? false,
          systemd ? false,
          uuid ? true,
          zstd ? true,
        }:
        let
          featureToggles = {
            inherit
              gssapi
              icu
              ldap
              libcurl
              libxml
              libxslt
              llvm
              lz4
              nls
              pam
              plperl
              plpython
              pltcl
              systemd
              zstd
              ;
            libnuma = libnuma && isLinux;
            liburing = liburing && isLinux;
          };

          featureDeps = {
            gssapi = [ pkgs.krb5 ];
            icu = [ pkgs.icu ];
            ldap = [ pkgs.openldap ];
            libcurl = [ pkgs.curl ];
            libnuma = lib.optionals isLinux [ pkgs.numactl ];
            liburing = lib.optionals isLinux [ pkgs.liburing ];
            libxml = [ pkgs.libxml2 ];
            libxslt = [ pkgs.libxslt ];
            llvm = [
              pkgs.llvmPackages.llvm
              pkgs.llvmPackages.clang
            ];
            lz4 = [ pkgs.lz4 ];
            nls = [ pkgs.gettext ];
            pam = lib.optionals isLinux [ pkgs.linux-pam ];
            plperl = [ pkgs.perl ];
            plpython = [ pkgs.python3 ];
            pltcl = [ pkgs.tcl ];
            systemd = lib.optionals isLinux [ pkgs.systemdLibs ];
            zstd = [ pkgs.zstd ];
          };
        in
        pkgs.stdenv.mkDerivation {
          pname = "postgresql";
          version = "dev";

          src = self;

          nativeBuildInputs = [
            pkgs.pkg-config
            pkgs.bison
            pkgs.flex
            pkgs.perl
            pkgs.python3
            pkgs.docbook_xsl
            pkgs.docbook-xsl-nons
          ];

          buildInputs = [
            pkgs.readline
            pkgs.zlib
          ]
          ++ lib.optional openssl pkgs.openssl
          ++ lib.optional uuid pkgs.libossp_uuid
          ++ lib.concatMap (
            name: if featureToggles.${name} or false then featureDeps.${name} or [ ] else [ ]
          ) (lib.attrNames featureToggles);

          configureFlags = [
            "--with-system-tzdata=${pkgs.tzdata}/share/zoneinfo"
            "--enable-cassert"
            "--enable-debug"
          ]
          ++ lib.optional openssl "--with-openssl"
          ++ lib.optional uuid "--with-uuid=ossp"
          ++ lib.optional gssapi "--with-gssapi"
          ++ lib.optional icu "--with-icu"
          ++ lib.optional ldap "--with-ldap"
          ++ lib.optional libcurl "--with-libcurl"
          ++ lib.optionals (libnuma && isLinux) [ "--with-libnuma" ]
          ++ lib.optionals (liburing && isLinux) [ "--with-liburing" ]
          ++ lib.optional libxml "--with-libxml"
          ++ lib.optional libxslt "--with-libxslt"
          ++ lib.optional llvm "--with-llvm"
          ++ lib.optional lz4 "--with-lz4"
          ++ (if nls then [ "--enable-nls" ] else [ "--disable-nls" ])
          ++ lib.optionals (pam && isLinux) [ "--with-pam" ]
          ++ lib.optional plperl "--with-perl"
          ++ lib.optional plpython "--with-python"
          ++ lib.optional pltcl "--with-tcl"
          ++ lib.optionals (systemd && isLinux) [ "--with-systemd" ]
          ++ lib.optional zstd "--with-zstd";

          enableParallelBuilding = true;

          meta = with lib; {
            description = "A powerful, open source object-relational database system";
            homepage = "https://www.postgresql.org";
            license = licenses.postgresql;
            platforms = platforms.unix;
          };
        };

      pgPackages = {
        postgresql = mkPostgresql { };
        postgresql-full = mkPostgresql {
          gssapi = true;
          ldap = true;
          libcurl = true;
          libnuma = true;
          liburing = true;
          nls = true;
          pam = true;
          plperl = true;
          plpython = true;
          pltcl = true;
          systemd = true;
        };
      };

      pgdata = "/tmp/pgdata";

      makepatch = pkgs.writeShellScriptBin "makepatch" ''
        version=""
        for arg in "$@"; do
          case "$arg" in
            -v[0-9]*) version="$arg"; shift ;;
          esac
        done
        git format-patch $version master --output-directory patches -- . ':!flake.nix' ':!flake.lock' ':!nix/' ':!.envrc' "$@"
      '';

      buildpg = pkgs.writeShellScriptBin "buildpg" ''
        nix build ".#postgresql-full" --print-build-logs "$@"
      '';

      buildpg2 = pkgs.writeShellScriptBin "buildpg2" ''
        set -e
        if [ ! -f GNUmakefile ]; then
          ./configure \
            --prefix="$PWD/build" \
            --with-system-tzdata=${pkgs.tzdata}/share/zoneinfo \
            --enable-cassert \
            --enable-debug \
            --with-openssl \
            --with-uuid=ossp \
            --with-icu \
            --with-libxml \
            --with-libxslt \
            --with-lz4 \
            --with-liburing \
            --with-pam \
            --with-systemd \
            --enable-tap-tests \
            --with-zstd
        fi
        make -j''$(nproc) "$@"
        make install
      '';

      initpg = pkgs.writeShellScriptBin "initpg" ''
        rm -rf ${pgdata}
        ./result/bin/initdb -D ${pgdata} --no-locale -U postgres \
          -c io_method=io_uring \
          -c log_min_messages=debug1
      '';

      startpg = pkgs.writeShellScriptBin "startpg" ''
        ./result/bin/pg_ctl -D ${pgdata} -l ${pgdata}/logfile start
      '';

      stoppg = pkgs.writeShellScriptBin "stoppg" ''
        ./result/bin/pg_ctl -D ${pgdata} stop
      '';

      connectpg = pkgs.writeShellScriptBin "connectpg" ''
        ./result/bin/psql -U postgres "$@"
      '';

      setup-clangd = pkgs.writeShellScriptBin "setup-clangd" ''
        bear -- make -j$(nproc) "$@"
        echo "compile_commands.json generated via bear"
      '';

      indentpg = pkgs.writeShellScriptBin "indentpg" ''
        set -e
        if [ ! -f GNUmakefile ]; then
          echo "Error: run ./configure first (or use checkpg to configure and build)" >&2
          exit 1
        fi
        make -C src/tools/pg_bsd_indent -j''$(nproc)
        export PATH="$PWD/src/tools/pg_bsd_indent:$PATH"
        perl src/tools/pgindent/pgindent "$@"
      '';

      fdleak = pkgs.writeShellScriptBin "fdleak" ''
        ls -la "/proc/''$(head -1 ${pgdata}/postmaster.pid)/fd/" | grep "io_uring" | wc -l
      '';

      pskill = pkgs.writeShellScriptBin "pskill" ''
        kill -9 ''$(./result/bin/psql -XtA -U postgres -c "SELECT pid FROM pg_stat_activity WHERE backend_type = 'client backend' LIMIT 1")
      '';

      checkpg = pkgs.writeShellScriptBin "checkpg" ''
        set -e
        if [ ! -f GNUmakefile ]; then
          ./configure \
            --with-system-tzdata=${pkgs.tzdata}/share/zoneinfo \
            --enable-cassert \
            --enable-debug \
            --with-openssl \
            --with-uuid=ossp \
            --with-icu \
            --with-libxml \
            --with-libxslt \
            --with-lz4 \
            --with-liburing \
            --with-pam \
            --with-systemd \
            --enable-tap-tests \
            --with-zstd
          make -j''$(nproc)
        fi
        rm -f src/test/regress/pg_regress.o src/test/regress/pg_regress
        make -C src/test/regress SHELL=/bin/sh pg_regress
        export LD_LIBRARY_PATH=$PWD/src/interfaces/libpq''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
        if [ "''${1:-}" = "installcheck" ]; then
          make installcheck PGHOST=/tmp PGUSER=postgres bindir=$PWD/result/bin
        elif [ "''${1:-}" = "check-world" ]; then
          make check-world -j8 >/dev/null
        else
          make check
        fi
      '';
    in
    {
      packages.${system} = pgPackages // {
        default = pgPackages.postgresql;
      };
      devShells.${system} = {
        default = pkgs.mkShell {
          name = "postgresql-dev";
          inputsFrom = [ self.packages.${system}.postgresql-full ];
          packages = [
            buildpg
            buildpg2
            checkpg
            makepatch
            initpg
            startpg
            stoppg
            connectpg
            indentpg
            fdleak
            pskill
            setup-clangd
            pkgs.bear
            pkgs.clang-tools
            pkgs.libpq
            pkgs.perlPackages.IPCRun
          ];
        };
      };
    };
}
