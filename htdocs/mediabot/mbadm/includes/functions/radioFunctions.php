<?php
	require_once('includes/conf/config.php');
	require_once('includes/functions/commonFunctions.php');
	
	// Check Radio Status
	function checkRadioStatus() {
		$fp = @fsockopen(LIQUIDSOAP_TELNET_SERVER_HOST, LIQUIDSOAP_TELNET_SERVER_PORT, $errno, $errstr, 10);
		if (!$fp) {
		    //echo "$errstr ($errno)<br />\n";
		    //echo "Liquidsoap est temporairement indisponile.";
		    return 0;
		}
		else {
			$out = "uptime\r\nquit\r\n";
	    fwrite($fp, $out);
	    $i = 0;
	    while (!feof($fp)) {
	    	$commandLine = fgets($fp, 128);
	    	if ( ( $commandLine != "\r\n" ) && ( $commandLine != "" ) && ( $commandLine != "END\r\n" ) && ( $commandLine != "Bye!\r\n" )) {
	      	$liquidsoapUptime = $commandLine;
	      	//echo "liquidsoapUptime = $liquidsoapUptime<br>\n";
	      }
	      $i++;
	    }
	    fclose($fp);
	    return 1;
		}
		
			
	}

	//function getCurrentSong() {
	//	$artist = exec ('echo -ne "output(dot)shoutcast.metadata\nquit\n" 2>/dev/null | nc localhost 1234 2>/dev/null | tail -n 18 | egrep "^artist" | cut -f2 -d"\""');
	//	if ( $artist == "" ) { $artist = "Artiste inconnu"; }
	//	$title = exec ('echo -ne "output(dot)shoutcast.metadata\nquit\n" 2>/dev/null | nc localhost 1234 2>/dev/null | tail -n 18 | egrep "^title" | cut -f2 -d"\""');
	//	if ( $title == "" ) { $title = "Titre inconnu"; }
	//	return "$artist - $title";
	//}
	
	function getHarborSource() {
		$fp = @fsockopen(LIQUIDSOAP_TELNET_SERVER_HOST, LIQUIDSOAP_TELNET_SERVER_PORT, $errno, $errstr, 10);
		if (!$fp) {
		    //echo "$errstr ($errno)<br />\n";
		    //echo "Liquidsoap est temporairement indisponile.";
		}
		else {
			$out = "src_4195.status\r\nquit\r\n";
	    fwrite($fp, $out);
	    $i = 0;
	    while (!feof($fp)) {
	    	$commandLine = fgets($fp, 128);
	    	if ( ( $commandLine != "\r\n" ) && ( $commandLine != "" ) && ( $commandLine != "END\r\n" ) && ( $commandLine != "Bye!\r\n" )) {
	      	$currentHarborConnection = $commandLine;
	      }
	      $i++;
	    }
	    fclose($fp);
		}
		if ( $currentHarborConnection  == "ERROR: unknown command, type \"help\" to get a list of commands.\r\n" ) {
			return ("RELAY");
		}
		else {
			return ($currentHarborConnection);
		}
	}
	
	function getCurrentSong() {
		// Check Harbor source
		$currentHarborSourceDJ = getHarborSource();
		$isSomeoneStreamingOnHarborSource = 0;
		if ( $currentHarborSourceDJ == "no source client connected\r\n" ) {
			//$currentLiquidSoapRid = lsRequestOnAirRid();
			//$currentLiveToDisplay = "<font color=\"green\">Playlist globale</font>&nbsp;(liquidsoap rid : $currentLiquidSoapRid)";
		}
		else {
			$isSomeoneStreamingOnHarborSource = 1;
			//$currentLiveToDisplay = "<font color=\"blue\">$currentHarborSourceDJ</font>";
		}
		
		if ( $isSomeoneStreamingOnHarborSource == 1 ) {
			$whatToMatch = "song";
		}
		else {
			$whatToMatch = "title";
		}
		$fp = fsockopen(LIQUIDSOAP_TELNET_SERVER_HOST, LIQUIDSOAP_TELNET_SERVER_PORT, $errno, $errstr, 10);
		$out = "output(dot)shoutcast.metadata\r\nquit\r\n";
		//echo "DEBUG: out=$out<br>\n";
		fwrite($fp, $out);
		$i = 0;
		while (!feof($fp)) {
			$commandLine = fgets($fp, 128);
    	if (preg_match("/^" . $whatToMatch . "/",$commandLine) == 1) {
    		$currentSong = preg_replace("/^" . $whatToMatch . "=(.*).*$/", "$1", $commandLine);
    		$currentSong = preg_replace("/^\"(.*)\".*$/", "$1", $currentSong);
    		//$currentSong = $commandLine;
    	}
			$i++;
		}
		fclose($fp);
		if ( !isset($currentSong) || ($currentSong == "" ) ) {
			return "Artiste inconnu - Titre inconnu";
		}
		else {
			return ($currentSong);
		}
	}
	
	function getNext() {
		$nextTracks = array();
		$fp = fsockopen(LIQUIDSOAP_TELNET_SERVER_HOST, LIQUIDSOAP_TELNET_SERVER_PORT, $errno, $errstr, 10);
		if (!$fp) {
		    echo "Liquidsoap est temporairement indisponile.";
		}
		else {
			$out = "playlist(dot)m3u.next\r\nquit\r\n";
	    fwrite($fp, $out);
	    $i = 0;
	    while (!feof($fp)) {
	    	$commandLine = fgets($fp, 128);
	    	if ( ($i != 0) && ( $commandLine != "\r\n" ) && ( $commandLine != "" ) && ( $commandLine != "END\r\n" ) && ( $commandLine != "Bye!\r\n" )) {
	      	$nextTracks[] = $commandLine;
	      }
	      $i++;
	    }
	    fclose($fp);
		}
		return ($nextTracks);
	}
	
	
	
function lsRequestOnAirRid() {
	$lsOnAir = "N/A";
	$fp = fsockopen(LIQUIDSOAP_TELNET_SERVER_HOST, LIQUIDSOAP_TELNET_SERVER_PORT, $errno, $errstr, 10);
	if (!$fp) {
		//echo "$errstr ($errno)<br />\n";
		echo "Liquidsoap est temporairement indisponile.";
	}
	else {
		//echo "DEBUG: Connecté au serveur telnet de liquidsoap<br>\n";
		$out = "request.on_air\r\nquit\r\n";
		//echo "DEBUG: out=$out<br>\n";
		fwrite($fp, $out);
		$i = 0;
		while (!feof($fp)) {
			//echo "DEBUG (line $i)<br>\n";
			$lsTelnetOutput = fgets($fp, 128);
			if ( ( $lsTelnetOutput != "\r\n" ) && ( $lsTelnetOutput != "" ) && ( $lsTelnetOutput != "END\r\n" ) && ( $lsTelnetOutput != "Bye!\r\n" )) {
				$lsOnAir = trim($lsTelnetOutput);
			}
			$i++;
		}
		fclose($fp);
	}
	return ($lsOnAir);
}

function lsRequestOnAirMetadata($rid) {
	$metadataRid = array();
	$fp = fsockopen(LIQUIDSOAP_TELNET_SERVER_HOST, LIQUIDSOAP_TELNET_SERVER_PORT, $errno, $errstr, 10);
	if (!$fp) {
		//echo "$errstr ($errno)<br />\n";
		echo "Liquidsoap est temporairement indisponile.";
	}
	else {
		//echo "DEBUG: Connecté au serveur telnet de liquidsoap<br>\n";
		$out = "request.metadata $rid\r\nquit\r\n";
		//echo "DEBUG: out=$out<br>\n";
		fwrite($fp, $out);
		$i = 0;
		while (!feof($fp)) {
			//echo "DEBUG (line $i)<br>\n";
			$lsTelnetOutput = fgets($fp, 128);
			if ( ( $lsTelnetOutput != "\r\n" ) && ( $lsTelnetOutput != "" ) && ( $lsTelnetOutput != "END\r\n" ) && ( $lsTelnetOutput != "Bye!\r\n" )) {
				$metadataRid[] = trim($lsTelnetOutput);
			}
			$i++;
		}
		fclose($fp);
	}
	return ($metadataRid);
}

?>
