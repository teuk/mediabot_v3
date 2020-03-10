<?php
	require_once('includes/conf/config.php');
	//Start session
	session_start();
	$_SESSION['SESS_PAGE_LEVEL'] = LEVEL_USER;
	require_once('includes/auth.php');
?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html lang="fr-FR">
<head>
	<meta http-equiv="Content-Type" content="text/html; charset=utf-8">
	<link rel="icon" type="image/jpg" href="favicon.jpg">
	<title>Aide</title>

    <!-- dhtmlx js functions -->
		<script type="text/javascript" src="codebase/dhtmlx.js"></script>

		<!-- dhtmlx css -->
		<link rel="stylesheet" type="text/css" href="codebase/dhtmlx.css">

		<script>
			function doOnLoad() {
				// Toolbar init
  			var helpToolbar = new dhtmlXToolbarObject("myhelpToolbar");
  			helpToolbar.setIconsPath("codebase/imgs/");
  			helpToolbar.addText("helpToolbarTitle1", 0, "<b>Aide Utilisateurs et Channels</b>");
  			
  			var helpToolbar2 = new dhtmlXToolbarObject("myhelpToolbar2");
  			helpToolbar2.setIconsPath("codebase/imgs/");
  			helpToolbar2.addText("helpToolbar2Title1", 0, "<b>Invocation des commandes</b>");
  			
  			var helpToolbar3 = new dhtmlXToolbarObject("myhelpToolbar3");
  			helpToolbar3.setIconsPath("codebase/imgs/");
  			helpToolbar3.addText("helpToolbar3Title1", 0, "<b>Liste des commandes publiques</b>");
  			
  			var helpToolbar4 = new dhtmlXToolbarObject("myhelpToolbar4");
  			helpToolbar4.setIconsPath("codebase/imgs/");
  			helpToolbar4.addText("helpToolbar4Title1", 0, "<b>Liste des commandes channels</b>");
  			
  			var helpToolbar5 = new dhtmlXToolbarObject("myhelpToolbar5");
  			helpToolbar5.setIconsPath("codebase/imgs/");
  			helpToolbar5.addText("helpToolbar5Title1", 0, "<b>Level 500</b>");
  			
  			var helpToolbar6 = new dhtmlXToolbarObject("myhelpToolbar6");
  			helpToolbar6.setIconsPath("codebase/imgs/");
  			helpToolbar6.addText("helpToolbar6Title1", 0, "<b>Level 450</b>");
			}

		</script>
		
</head>
<body onload="doOnLoad()">
<body>
	<div id="myhelpToolbar" style="width: 100%;"></div>
	<br>
	<div style="font-family: verdana, sans-serif">
		Un ensemble de commandes sont disponibles au niveau global "User"
		<br><br>
		Votre utilisateur a également un niveau entre 0 et 500 sur un channel donné
		<br><br>
		Le niveau 500 signifie que vous êtes propriétaire du channel donné
		<br>
		Le niveau 0 signifie que vous n'avez aucun accès au channel donné
	</div>
	<br>
	<div id="myhelpToolbar2" style="width: 100%;"></div>
	<br>
	<div style="font-family: verdana, sans-serif">
		La base de données comprend un ensemble de commandes listées sur la page d'accueil du site,<br>celles-ci ont été ajoutées par un utilisateur de niveau Administrator ou plus.
		<br>En plus de ces commandes en base, il existe une liste de commandes internes
		<br><br>
		Une commande est invoquée en tapant : <?php echo BOT_COMMANDCHAR ?>command arg1 arg2 etc. ou /msg <?php echo BOT_NICKNAME ?> command arg1 arg2 etc.
		<br><br>
		Elle peut nécessiter une authentification préalable, lorsque c'est le cas le message suivant apparaît en notice :
		<br><br>
		<div style="color: red;">
		-<?php echo BOT_NICKNAME ?>- You must be logged to use this command - /msg <?php echo BOT_NICKNAME ?> login username password
		</div>
		<br>
		Lors de l'ajout de votre utilisateur un Administrator vous a attribué un username (qui peut être différent de votre nick actuel).
		<br>Vous êtes également reconnu grâce à votre hostmask (ex : *ident@example.users.undernet.org).
		<br>Votre hostmask est également attribué par un Administrator à la création de votre utilisateur.
		<br>Il est possible d'en ajouter d'autres par la suite (voir la commande <a href="#ident">ident</a>).
		<br>Si vous lisez cette page vous avez dû effectuer au moins l'action suivante pour positionner votre mot de passe :
		<br><br>
		<div style="font-weight: bold;">
		/msg <?php echo BOT_NICKNAME ?> pass password
		</div>
		<br>
		"password" étant le mot de passe que vous avez choisi
		<br><br>Il est possible de réinitialiser ce mot de passe avec la commande :
		<br><br>
		<div style="font-weight: bold;">
		/msg <?php echo BOT_NICKNAME ?> newpass password
		</div>
		<br>
		Enfin pour s'authentifier il faut taper la commande suivante :
		<br><br>
		<div style="font-weight: bold;">
		/msg <?php echo BOT_NICKNAME ?> login username password
		</div>
		<br>
	</div>
	<div id="myhelpToolbar3" style="width: 100%;"></div>
	<br>
	<div style="font-family: verdana, sans-serif">
		Les commandes peuvent être invoquées en privé ou sur un channel de la manière suivante :
		<br><br>
		Privé : <div style="font-weight: bold;">
		<br>
		/msg <?php echo BOT_NICKNAME ?> commande arg1 arg2 ...
		</div>
		<br>
		Publiquement sur un channel : <div style="font-weight: bold;">
		<br>
		<?php echo BOT_COMMANDCHAR ?>commande arg1 arg2 ...
		<br>
		<?php echo BOT_NICKNAME ?> commande arg1 arg2 ...
		</div>
		<br>
			Les commandes sont notées *commande pour celles qui ne sont disponibles qu'en privé
			<br>
			Les commandes sont notées +commande pour celles qui ne sont disponibles qu'en public
			<br>
			Les commandes non préfixées par * ou + sont accessibles via les deux méthodes
			<br>
			Lorsque que l'argument [#channel] est spécifié il est optionnel
			<br>
			Si #channel n'est pas spécifié, c'est le channel sur laquelle la commande est invoquée qui est pris en compte
			<br><br>
			<div id="ident" style="font-weight: bold">*ident username password</div>
			<br>
			Ajouter le hostmask actuel lorsque celui-ci n'est pas présent dans la base
			<br><br>
			<div style="font-weight: bold">showcommands [#channel]</div>
			<br>
			Lister les commandes "channels" disponibles selon le niveau de l'utilisateur sur celui-ci
			<br><br>
			<div style="font-weight: bold">chaninfo [#channel]</div>
			<br>
			Afficher les informations du channel spécifié
			<br><br>
			<div style="font-weight: bold">*verify nickname</div>
			<br>
			Vérifie si nickname est authentifié et affiche son username (celui-ci peut être différent de nickname)
			<br><br>
			<div style="font-weight: bold">access [#channel] username</div>
			<br>
			Affiche le niveau de l'utilisateur sur le channel spécifié
			<br><br>
			<div style="font-weight: bold">showcmd command</div>
			<br>
			Affiche la description d'une commande ajoutée par addcmd, son auteur et le nombre d'invocation de celle-ci
			<br><br>
			<div style="font-weight: bold">+version</div>
			<br>
			Affiche la version du bot
			<br><br>
			<div style="font-weight: bold">+countcmd</div>
			<br>
			Affiche le nombre de commande ajoutées via addcmd et par catégories
			<br><br>
			<div style="font-weight: bold">+topcmd</div>
			<br>
			Affiche le top 20 des commandes ajoutées via addcmd
			<br><br>
			<div style="font-weight: bold">+searchcmd keyword</div>
			<br>
			Affiche les commandes ajoutées via addcmd contenant keyword
			<br><br>
			<div style="font-weight: bold">+lastcmd</div>
			<br>
			Affiche les commandes 10 dernières commandes ajoutées via addcmd
			<br><br>
			<div style="font-weight: bold">+owncmd</div>
			<br>
			Affiche le nombre de commandes ajoutées via addcmd par username
			<br><br>
			<div style="font-weight: bold">whoami</div>
			<br>
			Affiche les informations de l'utilisateur
		<br><br>
	</div>
	<div id="myhelpToolbar4" style="width: 100%;"></div>
	<div style="font-family: verdana, sans-serif">
		<br>
		Les commandes channels sont disponibles selon votre niveau sur celui-ci.
		<br>
		Le channel est attribué par un Administrator à un utilisateur qui a le niveau 500 (propriétaire).
		<br>
		Celui-ci peut ensuite ajouter des utilisateurs à un niveau donné sur son channel (cf command <a href="#add">add</a>)
		<br><br>
	</div>
	<div id="myhelpToolbar5" style="width: 100%;"></div>
	<div style="font-family: verdana, sans-serif">
		<br>
		<div style="font-weight: bold">part [#channel]</div>
		<br>
		Faire partir <?php echo BOT_NICKNAME ?> du channel spécifié
	</div>
	<br>
	<div id="myhelpToolbar6" style="width: 100%;"></div>
<br><br>
</body>
</html>