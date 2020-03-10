<?php
	require_once('includes/conf/config.php');
	require_once('includes/auth.php');
	
	$procInfoExec = exec("ps -eafw",$procInfoResults);
	
	function addSubProcess($current_id_process,$current_description) {
		global $procInfoResults;
		$html = <<< EOH
		<item text="$current_description" id="processNodeId$current_id_process" open="yes">
EOH;

		echo($html);
		
		for($i=1;$i<sizeof($procInfoResults);$i++) {

			$procInfoResults2 = preg_split ( "/\s+/" , $procInfoResults[$i] );
			$UID = $procInfoResults2[0];
			$PID = $procInfoResults2[1];
			$PPID = $procInfoResults2[2];
			$C = $procInfoResults2[3];
			$STIME = $procInfoResults2[4];
			$TTY = $procInfoResults2[5];
			$TIME = $procInfoResults2[6];
			$CMD = $procInfoResults2[7];
			
			if ( $PPID == $current_id_process) {
				$strProcessDescription = $CMD . " ($PID)";
				if ( $TTY != "?" ) {
					$strProcessDescription .= " on $TTY";
				}
				addSubProcess($PID,$strProcessDescription);
			}
		}
		$html = <<< EOH
		</item>
EOH;

		echo($html);
	}
	
	header('Content-type: text/xml');
	$html = <<< EOH
<?xml version="1.0" encoding="UTF-8"?>
<tree id="0">
EOH;

echo ($html);

addSubProcess(1,"init");

$html = <<< EOH
</tree>
EOH;

echo ($html);
?>
