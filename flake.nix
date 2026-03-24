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

      gitRemotes = {
        upstream = "https://git.postgresql.org/git/postgresql.git";
      };

      remotesScript = lib.concatMapStringsSep "\n" (name: ''
        url=${lib.escapeShellArg gitRemotes.${name}}
        if current=$(git remote get-url ${name} 2>/dev/null); then
          if [ "$current" = "$url" ]; then
            echo "ok     ${name} -> $url"
          else
            git remote set-url ${name} "$url"
            echo "update ${name} -> $url (was $current)"
          fi
        else
          git remote add ${name} "$url"
          echo "add    ${name} -> $url"
        fi
      '') (lib.attrNames gitRemotes);

      commands = {
        build = {
          description = "Build PostgreSQL via Nix (postgresql-full)";
          script = ''
            nix build ".#postgresql-full" --print-build-logs "$@"
          '';
        };

        build2 = {
          description = "Configure and build PostgreSQL locally (no Nix derivation)";
          script = ''
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
            make -j$(nproc) "$@"
            make install
          '';
        };

        tests = {
          description = "Run regression tests (optional: installcheck, check-world)";
          script = ''
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
              make -j$(nproc)
            fi
            rm -f src/test/regress/pg_regress.o src/test/regress/pg_regress
            make -C src/test/regress SHELL=/bin/sh pg_regress
            export LD_LIBRARY_PATH=$PWD/src/interfaces/libpq''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
            case "''${1:-}" in
              installcheck) make installcheck PGHOST=/tmp PGUSER=postgres bindir=$PWD/result/bin ;;
              check-world) make check-world -j8 >/dev/null ;;
              *) make check ;;
            esac
          '';
        };

        connect = {
          description = "Connect to the running server with psql";
          script = ''
            ./result/bin/psql -U postgres "$@"
          '';
        };

        fdleak = {
          description = "Count io_uring file descriptors held by postmaster";
          script = ''
            ls -la "/proc/$(head -1 ${pgdata}/postmaster.pid)/fd/" | grep "io_uring" | wc -l
          '';
        };

        indent = {
          description = "Run pgindent on the source tree";
          script = ''
            set -e
            if [ ! -f GNUmakefile ]; then
              echo "Error: run ./configure first (or use checkpg to configure and build)" >&2
              exit 1
            fi
            make -C src/tools/pg_bsd_indent -j$(nproc)
            export PATH="$PWD/src/tools/pg_bsd_indent:$PATH"
            perl src/tools/pgindent/pgindent "$@"
          '';
        };

        init = {
          description = "Initialize a fresh cluster at ${pgdata}";
          script = ''
            rm -rf ${pgdata}
            ./result/bin/initdb -D ${pgdata} --no-locale -U postgres \
              -c io_method=io_uring \
              -c log_min_messages=debug1
          '';
        };

        remotes = {
          description = "Apply declared git remotes (idempotent)";
          script = remotesScript;
        };

        patch = {
          description = "Create git format-patches from master (optional: -v<N>)";
          script = ''
            version=""
            for arg in "$@"; do
              case "$arg" in
                -v[0-9]*) version="$arg"; shift ;;
              esac
            done
            git format-patch $version master --output-directory patches -- . ':!flake.nix' ':!flake.lock' ':!nix/' ':!.envrc' "$@"
          '';
        };

        kill = {
          description = "SIGKILL the first client backend in pg_stat_activity";
          script = ''
            kill -9 $(./result/bin/psql -XtA -U postgres -c "SELECT pid FROM pg_stat_activity WHERE backend_type = 'client backend' LIMIT 1")
          '';
        };

        setup-clangd = {
          description = "Generate compile_commands.json via bear";
          script = ''
            bear -- make -j$(nproc) "$@"
            echo "compile_commands.json generated via bear"
          '';
        };

        start = {
          description = "Start the local PostgreSQL server";
          script = ''
            ./result/bin/pg_ctl -D ${pgdata} -l ${pgdata}/logfile start
          '';
        };

        stop = {
          description = "Stop the local PostgreSQL server";
          script = ''
            ./result/bin/pg_ctl -D ${pgdata} stop
          '';
        };

        update = {
          description = "Rebase the current branch onto upstream/master";
          script = ''
            git pull upstream master --rebase "$@"
          '';
        };
      };

      commandNames = lib.attrNames commands;

      maxNameLen = lib.foldl' (acc: n: if n > acc then n else acc) 0 (
        map lib.stringLength commandNames
      );

      padRight =
        s:
        s + lib.concatStrings (lib.genList (_: " ") (maxNameLen - lib.stringLength s));

      helpLines = lib.concatMapStringsSep "\n" (
        name: "  ${padRight name}  ${commands.${name}.description}"
      ) commandNames;

      caseBranches = lib.concatMapStringsSep "\n" (name: ''
        ${name})
          shift
          ${commands.${name}.script}
          ;;
      '') commandNames;

      helpText = ''
        Usage: pgdev <command> [args...]

        A developer CLI for the PostgreSQL build & test workflow.

        Commands:
        ${helpLines}

        Run 'pgdev --help' to show this message.
      '';

      pgdev = pkgs.writeShellScriptBin "pgdev" ''
        case "''${1:-}" in
          "" | -h | --help)
            printf '%s' ${lib.escapeShellArg helpText}
            ;;
          ${caseBranches}
          *)
            echo "pgdev: unknown command '$1'" >&2
            echo "Run 'pgdev --help' for a list of commands." >&2
            exit 1
            ;;
        esac
      '';

      pgdevFishCompletions = pkgs.writeTextFile {
        name = "pgdev-fish-completions";
        destination = "/share/fish/vendor_completions.d/pgdev.fish";
        text = ''
          complete -c pgdev -f
          complete -c pgdev -n __fish_use_subcommand -l help -d 'Show help'
          complete -c pgdev -n __fish_use_subcommand -s h    -d 'Show help'
        ''
        + lib.concatMapStrings (name:
          "complete -c pgdev -n __fish_use_subcommand -a ${name} -d ${lib.escapeShellArg commands.${name}.description}\n"
        ) commandNames;
      };
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
            pgdev
            pgdevFishCompletions
            pkgs.bear
            pkgs.clang-tools
            pkgs.libpq
            pkgs.perlPackages.IPCRun
          ];
        };
      };
    };
}
