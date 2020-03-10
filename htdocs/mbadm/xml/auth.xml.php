<?php
	require_once('../includes/conf/config.php');
	require_once('../includes/functions/commonFunctions.php');
	require_once('../includes/functions/dbConnect.php');


	//Function to sanitize values received from the form. Prevents SQL injection
	function clean($link,$str) {
		$str = @trim($str);
		if(get_magic_quotes_gpc()) {
			$str = stripslashes($str);
		}
		return mysqli_real_escape_string($link,$str);
	}
	
	header('Content-type: text/xml');

//Sanitize the POST values
$login = clean($link,$_POST['login']);
$password = clean($link,$_POST['credential']);
$auth_success = 0;
$ip = $_SERVER['REMOTE_ADDR'];
$hostname = gethostbyaddr($ip);

if ( ( $login != "" ) && ( $password != "" ) ) {
	//Create query
	$loginQuery = "SELECT * FROM USER WHERE nickname='$login' AND password=PASSWORD('" . $password . "')";
	//error_log($loginQuery);
	
	$result=mysqli_query($link,$loginQuery);
	
	if($result) {
		if($result->num_rows == 1) {
			$auth_success = 1;
		}
	}
}

$html = <<< EOH
<?xml version="1.0" encoding="UTF-8"?>
	<authentication>$auth_success</authentication>

EOH;

	echo ($html);
?>
<?php
	
	
	if ( $auth_success == 1 ) {
		//Start session
		session_start();
		//Create query
		$loginQuery = "SELECT * FROM USER,USER_LEVEL WHERE USER.id_user_level=USER_LEVEL.id_user_level AND nickname='$login' AND password=PASSWORD('" . $password . "')";
		//error_log($loginQuery);
		$result=mysqli_query($link,$loginQuery);
		//Check whether the query was successful or not
		if($result) {
			if($result->num_rows == 1) {
				//Login Successful
				session_regenerate_id();
				$member = mysqli_fetch_assoc($result);
				$_SESSION['SESS_MEMBER_ID'] = $member['id_user'];
				$_SESSION['SESS_MEMBER_LOGIN'] = $member['nickname'];
				$_SESSION['SESS_MEMBER_LEVEL'] = $member['level'];
				$_SESSION['SESS_MEMBER_LEVEL_DESC'] = _convert($member['description']);
				
				session_write_close();
				$logHostname = gethostbyaddr($_SERVER['REMOTE_ADDR']);
				$connectionLogQuery = "INSERT INTO WEBLOG (login_date,nickname,password,ip,hostname,logresult) VALUES ('" . date("Y-m-d H:i:s") . "','" . $_SESSION['SESS_MEMBER_LOGIN']. "',NULL,'" . $_SERVER['REMOTE_ADDR'] . "','" . $logHostname ."',1)";
				//error_log($connectionLogQuery);
			 	$req = mysqli_query($link,$connectionLogQuery,$link);
			 	if ( ML_ALERTS_SUCCESS_ENABLED ) {
				 	if ( !mail_utf8(ML_ALERTS, "Connexion à l'interface d'administration de " . PORTAL_NAME . " : " . $_SESSION['SESS_MEMBER_LOGIN'] . " (" . $_SERVER['REMOTE_ADDR'] . " - $logHostname ) ","[" . date("d/m/Y H:i:s") . "] L'utilisateur : " . $_SESSION['SESS_MEMBER_LOGIN'] . " s'est connecté depuis l'adresse : " . $_SERVER['REMOTE_ADDR'] . " ( $logHostname )") ) {
						error_log("Could not send connection login mail to " . ML_ALERTS, 0);
					}
				}
		
			}
			else {
				$logHostname = gethostbyaddr($_SERVER['REMOTE_ADDR']);
				$connectionLogQuery = "INSERT INTO WEBLOG (login_date,nickname,password,ip,hostname,logresult) VALUES ('" . date("Y-m-d H:i:s") . "','" . $_SESSION['SESS_MEMBER_LOGIN']. "',$password,'" . $_SERVER['REMOTE_ADDR'] . "','" . $logHostname ."',0)";
				//error_log($connectionLogQuery);
			 	$req = mysqli_query($link,$connectionLogQuery,$link);
			 	if ( ML_ALERTS_FAIL_ENABLED ) {
				 	if ( !mail_utf8(ML_ALERTS, "Tentative de connexion à l'interface d'administration de " . PORTAL_NAME . " : " . $_SESSION['SESS_MEMBER_LOGIN'] . " (" . $_SERVER['REMOTE_ADDR'] . " - $logHostname ) ","[" . date("d/m/Y H:i:s") . "] L'utilisateur : " . $_SESSION['SESS_MEMBER_LOGIN'] . " a tenté de se connecter depuis l'adresse : " . $_SERVER['REMOTE_ADDR'] . " ( $logHostname )") ) {
						error_log("Could not send connection login mail to " . ML_ALERTS, 0);
					}
				}
				
			}
			exit();
		}
	}

?>