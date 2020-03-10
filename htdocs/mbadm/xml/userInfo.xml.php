<?php
	require_once('includes/conf/config.php');
	require_once('includes/auth_xml.php');
	
	header('Content-type: text/xml');
	$html = <<< EOH
<?xml version="1.0" encoding="UTF-8"?>
<rows>
EOH;

echo ($html);

$my_session_member_id = $_SESSION['SESS_MEMBER_ID'];
$my_session_member_login = $_SESSION['SESS_MEMBER_LOGIN'];
$my_session_member_level = $_SESSION['SESS_MEMBER_LEVEL'];
$my_session_member_level_desc = $_SESSION['SESS_MEMBER_LEVEL_DESC'];

$html = <<< EOH
      	<row id="tportalUserInfo">
      		<cell>$my_session_member_id</cell>
      		<cell>$my_session_member_login</cell>
	   			<cell>$my_session_member_level</cell>
	   			<cell>$my_session_member_level_desc</cell>
				</row>
EOH;

echo($html);

$html = <<< EOH
</rows>
EOH;

echo ($html);
?>
