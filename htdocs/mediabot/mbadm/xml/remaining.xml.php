<?php
	require_once('includes/conf/config.php');
	
	header('Content-type: text/xml');
	$html = <<< EOH
<?xml version="1.0" encoding="UTF-8"?>
<rows>
EOH;

echo ($html);

$fp = fsockopen("localhost", 1234, $errno, $errstr, 30);
if (!$fp) {
    echo "$errstr ($errno)<br />\n";
} else {
    $out = "radio(dot)mp3.remaining\r\n";
    $out .= "quit\r\n";

    fwrite($fp, $out);
    if (!feof($fp)) {
        $strSecondsRemaining = fgets($fp, 128);
        $strMinutesRemaining = intval($strSecondsRemaining / 60 );
        $strSecsRemaining = intval($strSecondsRemaining - ( $strMinutesRemaining * 60 ));
        $strTimeRemaining = $strMinutesRemaining . "mn";
        if ( $strMinutesRemaining > 1 ) {
        	$strTimeRemaining .= "s";
        }
        $strTimeRemaining .= " $strSecsRemaining sec";
        if ( $strSecsRemaining > 1 ) {
        	$strTimeRemaining .= "s";
        }
    }
    fclose($fp);
}

$html = <<< EOH
<remaining>$strTimeRemaining</remaining>
EOH;

echo($html);

$html = <<< EOH
</rows>
EOH;

echo ($html);
?>
