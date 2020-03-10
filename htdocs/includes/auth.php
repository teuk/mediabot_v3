<?php
	//Start session if it does not exist
	if (session_status() == PHP_SESSION_NONE) {
    session_start();
	}
	
	//Check whether the session variable SESS_MEMBER_ID is present or not
	if(!isset($_SESSION['SESS_MEMBER_ID']) || (trim($_SESSION['SESS_MEMBER_ID']) == '') ) {
		$html = <<< EOH
		<script>
			document.location = "index.php";
		</script>
EOH;

		echo($html);
		exit();
	}
	
	if (isset($_SESSION['SESS_PAGE_LEVEL']) && ($_SESSION['SESS_MEMBER_LEVEL'] > $_SESSION['SESS_PAGE_LEVEL'])) {
		unset($_SESSION['SESS_PAGE_LEVEL']);
		exit();
	}
?>
