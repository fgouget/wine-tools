<?php
include("config.php");

header("Content-type: text/plain");
$f = fopen("$DATAROOT/run.log", "r");
fpassthru($f);
?>
