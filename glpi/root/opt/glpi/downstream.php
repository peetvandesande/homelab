<?php
// Installed as inc/downstream.php in each GLPI release under /opt/glpi: the
// configuration lives in /etc/glpi. GLPI 11 reads local_define.php only from
// its own config/ directory, whatever its install guide says, so this file
// loads the one in /etc/glpi itself.
define('GLPI_CONFIG_DIR', '/etc/glpi');
if (file_exists(GLPI_CONFIG_DIR . '/local_define.php')) {
    require_once GLPI_CONFIG_DIR . '/local_define.php';
}
