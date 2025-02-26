self: {
  config,
  pkgs,
  lib,
  ...
}: let
  inherit (lib.modules) mkIf;
  inherit (lib.options) mkOption mkEnableOption;
  inherit (lib.types) attrsOf oneOf str bool int enum;
  inherit (lib.lists) optionals;

  pterodactylPhp83 = pkgs.php83.buildEnv {
    extensions = {
      enabled,
      all,
    }:
      enabled
      ++ (with all; [
        redis
        xdebug
      ]);

    extraConfig = ''
      xdebug.mode=debug
    '';
  };

  pterodactylComposer = pkgs.php81Packages.composer.override {php = pterodactylPhp83;};

  cfg = config.services.pterodactyl;
in {
  options.services.pterodactyl = {
    enable = mkEnableOption "pterodactyl panel";

    user = mkOption {
      type = str;
      default = "pterodactyl";
      description = "The user under which the panel will run";
    };

    group = mkOption {
      type = str;
      default = "pterodactyl";
      description = "The group under which the panel will run";
    };

    dataDir = mkOption {
      type = str;
      default = "/var/www/pterodactyl";
      description = ''
        The directory containing the panel files.

        For immutability reasons, we do not automatically unpack the panel, nor can we set
        the store directory
      '';
    };

    panel = mkOption {
      type = enum ["pterodactyl" "pelican-dev"];
      default = "pterodactyl";
      description = ''
        Panel type to use. Can be either 'pterodactyl' or 'pelican-dev'.
      '';
    };

    appName = mkOption {
      type = str;
      default = "Pterodactyl";
      description = ''
        Custom app name for the panel that will show up to users instead of the default.
      '';
    };

    # Database Setup
    database = {
      mysql = {
        createLocally = mkOption {
          type = bool;
          default = false;
          description = ''
            Create the MySQL database and database user locally, and run installation.
            The mysql database will be handled declaratively, however do note that the panel
            settings will only be set at startup, any addtions need to be done in <dataDir>/.env.
          '';
        };

        options = mkOption {
          type = attrsOf (oneOf [
            str
            bool
            int
          ]);
          description = "MySQL database parameters";
          default = {
            host = "127.0.0.1";
            port = 3306;
            username = "pterodactyl";
            database = "panel";
            strict = false;
          };
        };
      };

      redis = {
        createLocally = mkOption {
          type = bool;
          default = false;
          description = ''
            Create the Redis database and database user locally, and run installation.
            The redis database will be handled declaratively, however do note that the panel
            settings will only be set at startup, any addtions need to be done in <dataDir>/.env.
          '';
        };

        options = mkOption {
          type = attrsOf (oneOf [
            str
            bool
            int
          ]);
          description = "Redis database parameters";
          default = {
            username = "pterodactyl";
            database = "panel";
            password = "pterodactyl";
          };
        };
      };
    };
  };

  config = mkIf cfg.enable {
    # createHome doesn't make the directory with correct permissions, and will actively revert permissions
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0770 ${cfg.user} ${cfg.group} -"
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      createHome = false;
      home = cfg.dataDir;
      group = cfg.user;
    };

    users.groups.${cfg.group} = {
      members =
        [cfg.user]
        ++ optionals config.services.caddy.enable [config.services.caddy.user]
        ++ optionals config.services.nginx.enable [config.services.nginx.user];
    };

    services = {
      mysql = mkIf cfg.database.mysql.createLocally {
        enable = true;
        package = pkgs.mysql80;
        ensureDatabases = [cfg.database.mysql.options.database];

        # Pterodactyl expects mysql authentication to be done with mysql_native_password
        # not in love with doing this, however it doesn't work without it.
        initialScript =
          pkgs.writeText "panel-mysql-setup"
          ''
            CREATE USER IF NOT EXISTS '${cfg.database.mysql.options.username}'@'localhost' IDENTIFIED WITH mysql_native_password BY '${cfg.database.mysql.options.password}';
            GRANT ALL ON ${cfg.database.mysql.options.database}.* TO '${cfg.database.mysql.options.username}'@'localhost';
          '';

        # ensureUsers = [
        #   {
        #     name = cfg.database.mysql.options.username;
        #     ensurePermissions = {
        #       "${cfg.database.mysql.options.database}.*" = "ALL PRIVILEGES";
        #     };
        #   }
        # ];
      };

      redis.servers."${cfg.database.redis.options.database}" = {
        enable = true;
        port = cfg.database.redis.options.port;
        user = cfg.database.redis.options.username;
        bind = cfg.database.redis.options.host;

        settings = {
          requirepass = cfg.database.redis.options.password;
        };
      };

      phpfpm.pools.pterodactyl = {
        phpPackage = pterodactylPhp83;
        user = cfg.user;
        group = cfg.group;

        phpEnv = {
          DB_CONNECTION = "mysql";
          DB_DATABASE = cfg.database.mysql.options.database;
          DB_HOST = cfg.database.mysql.options.host;
          DB_PORT = toString cfg.database.mysql.options.port;
          DB_USERNAME = cfg.database.mysql.options.username;
          DB_PASSWORD = cfg.database.mysql.options.password;

          REDIS_HOST = cfg.database.redis.options.host;
          REDIS_PORT = toString cfg.database.redis.options.port;
          REDIS_PASSWORD = cfg.database.redis.options.password;

          APP_NAME = cfg.appName;
          QUEUE_CONNECTION = "redis";
          CACHE_STORE = "redis";
          SESSION_DRIVER = "cookie";
          APP_URL = "http://localhost"; # TODO: change
          APP_INSTALLED = "true";
        };

        settings = {
          "listen.owner" = cfg.user;

          "pm" = "dynamic";
          "pm.start_servers" = 4;
          "pm.min_spare_servers" = 4;
          "pm.max_spare_servers" = 16;
          "pm.max_children" = 64;
          "pm.max_requests" = 256;

          "clear_env" = false;
          "catch_workers_output" = true;
          "decorate_workers_output" = false;
          "php_admin_value[error_log]" = "stderr";
          "php_admin_flag[daemonize]" = "false";
        };
      };

      cron = {
        enable = true;
        systemCronJobs = [
          "* * * * *  ${pterodactylPhp83} ${cfg.dataDir}/artisan schedule:run >> /dev/null 2>&1"
        ];
      };
    };

    systemd = {
      services.pterodactyl-setup = {
        description = "Pterodactyl Panel Setup";
        requires = ["mysql.service" "redis-${cfg.database.redis.options.database}.service" "network-online.target"];
        after = ["mysql.service" "redis-${cfg.database.redis.options.database}.service" "network-online.target"];
        before = ["pteroq.service" "pterodactyl-cron.service"];
        wantedBy = ["multi-user.target"];

        path = with pkgs; [
          curl
          gzip
          gnutar
          pterodactylPhp83
          pterodactylComposer
          mysql80
          redis
        ];

        environment = {
          DB_CONNECTION = "mysql";
          DB_DATABASE = cfg.database.mysql.options.database;
          DB_HOST = cfg.database.mysql.options.host;
          DB_PORT = toString cfg.database.mysql.options.port;
          DB_USERNAME = cfg.database.mysql.options.username;
          DB_PASSWORD = cfg.database.mysql.options.password;

          REDIS_HOST = cfg.database.redis.options.host;
          REDIS_PORT = toString cfg.database.redis.options.port;
          REDIS_PASSWORD = cfg.database.redis.options.password;
        };

        serviceConfig = {
          Type = "oneshot";
          User = cfg.user;
          Group = cfg.user;
          RemainAfterExit = true;
          ExecStart = "${(pkgs.writeShellApplication {
            name = "pterodactyl-setup";
            text = ''
              MARKER_FILE="${cfg.dataDir}/.setup-complete"

              if [ ! -f "$MARKER_FILE" ]; then
                # 1. Download panel files
                curl -L https://github.com/${cfg.panel}/panel/releases/latest/download/panel.tar.gz | tar -xzv -C "${cfg.dataDir}"

                # 2. Install composer dependencies
                cd "${cfg.dataDir}"
                composer install --no-dev --optimize-autoloader

                # 3. Run environment setup
                php artisan p:environment:setup

                # 4. Run database migrations
                php artisan migrate --seed --force

                # 5. Create marker file to indicate setup is complete
                touch "$MARKER_FILE"

                # 6. Set correct permissions
                chown -R ${cfg.user}:${cfg.group} "${cfg.dataDir}"
                chmod -R 770 "${cfg.dataDir}" # webserver needs to have full access over directory
              fi
            '';
          })}/bin/pterodactyl-setup";
        };
      };

      services.pteroq = {
        description = "Pterodactyl Queue Worker";
        requires = ["mysql.service" "redis-${cfg.database.redis.options.database}.service"];
        after = ["mysql.service" "redis-${cfg.database.redis.options.database}.service" "pterodactyl-setup.service"];
        unitConfig = {StartLimitInterval = 180;};
        serviceConfig = {
          User = cfg.user;
          Group = cfg.user;
          Restart = "always";
          ExecStart = "${pterodactylPhp83}/bin/php ${cfg.dataDir}/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3";
          StartLimitBurst = 30;
          RestartSec = "5s";
        };
        wantedBy = ["multi-user.target"];
        environment = {
          # Disable telemetry.
          PTERODACTYL_TELEMETRY_ENABLED = "false";
        };
      };
    };

    environment.systemPackages = [
      pterodactylPhp83
      pterodactylComposer
    ];
  };
}
