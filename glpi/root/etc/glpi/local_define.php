<?php
// GLPI's data, logs and plugins, outside the code in /opt/glpi so an upgrade
// replaces the code alone. Loaded through inc/downstream.php, which names this
// directory as GLPI_CONFIG_DIR. Installed by infra/ansible/roles/glpi.
define('GLPI_VAR_DIR', '/var/lib/glpi/files');
define('GLPI_MARKETPLACE_DIR', '/var/lib/glpi/marketplace');
define('GLPI_LOG_DIR', '/var/log/glpi');
