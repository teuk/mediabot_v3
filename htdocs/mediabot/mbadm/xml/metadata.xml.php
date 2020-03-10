<?php
	require_once('includes/conf/config.php');
	
	header('Content-type: text/xml');
	$html = <<< EOH
<?xml version="1.0" encoding="UTF-8"?>

EOH;

$json_icecast = file_get_contents('http://teuk.org:8000/status-json.xsl');

$json_array = json_decode($json_icecast, true);

$metadata = htmlspecialchars($json_array["icestats"]["source"]["title"],ENT_QUOTES | ENT_SUBSTITUTE | ENT_DISALLOWED);

$html = <<< EOH
<metadata>$metadata</metadata>
EOH;

echo($html);
