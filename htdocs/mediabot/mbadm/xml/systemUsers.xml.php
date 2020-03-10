<?php
	//Start session
	session_start();
	$_SESSION['SESS_XML_LEVEL'] = 1;
	require_once('includes/conf/config.php');
	require_once('includes/auth_xml.php');

	$usersInfoExec = exec("cat /etc/passwd | awk -F\":\" '{print $3 \" \" $0}' | sort -n",$usersInfoResults);
	
	header('Content-type: text/xml');
	$html = <<< EOH
<?xml version="1.0" encoding="UTF-8"?>
<rows>
EOH;

echo ($html);

for($i=0;$i<sizeof($usersInfoResults);$i++) {
	$usersInfoResults2 = preg_split ( "/:/" , $usersInfoResults[$i] ) ;
	
	//$username = $usersInfoResults2[0];
	$usernameStr = (preg_split ( "/\s/" , $usersInfoResults2[0] )) ;
	$username = $usernameStr[1];
	$useruid = $usersInfoResults2[2];
	$usergid = $usersInfoResults2[3];
	$comment = $usersInfoResults2[4];
	$homedir = $usersInfoResults2[5];
	$shell = $usersInfoResults2[6];
	
$html = <<< EOH
      	<row id="userInfoId$i">
      		<cell>$username</cell>
	   			<cell>$useruid</cell>
	   			<cell>$usergid</cell>
	   			<cell>$comment</cell>
	   			<cell>$homedir</cell>
	   			<cell>$shell</cell>
				</row>

EOH;

echo($html);

}

$html = <<< EOH
</rows>
EOH;

echo ($html);
?>
