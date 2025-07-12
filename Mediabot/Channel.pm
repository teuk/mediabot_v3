package Mediabot::Channel;

use strict;
use warnings;
use DBI;

sub new {
    my ($class, $args) = @_;
    my $self = {
        id        => $args->{id},
        name      => $args->{name},
        description => $args->{description} || '',
        topic     => $args->{topic},
        tmdb_lang => $args->{tmdb_lang},
        chanmode => $args->{chanmode},
        auto_join => $args->{auto_join},
        key       => $args->{key},
        dbh       => $args->{dbh},  # needed for SQL updates
        irc       => $args->{irc},  # needed for IRC operations
    };
    bless $self, $class;
    return $self;
}

# ------------------------
# GETTERS
# ------------------------

# Get channel ID
sub get_id         { return shift->{id}; }

# Get channel name (e.g. #channel)
sub get_name       { return shift->{name}; }

# Get channel description
sub get_description { return shift->{description}; }

# Get current topic
sub get_topic      { return shift->{topic}; }

# Get TMDB language (e.g. en-US, fr-FR)
sub get_tmdb_lang  { return shift->{tmdb_lang}; }

# Get channel key (password)
sub get_key        { return shift->{key}; }

# Get auto_join status
sub get_auto_join        { return shift->{auto_join}; }

# Get chanmode status
sub get_chanmode        { return shift->{chanmode}; }

# Get user level in this channel
sub get_user_level {
    my ($self, $nickname) = @_;
    my $level = 0;

    my $sth = $self->{dbh}->prepare(q{
        SELECT level
        FROM USER
        JOIN USER_CHANNEL USING (id_user)
        WHERE id_channel = ?
          AND nickname = ?
    });

    if ($sth->execute($self->{id}, $nickname)) {
        if (my $ref = $sth->fetchrow_hashref) {
            $level = $ref->{level};
        }
    } else {
        $self->{logger}->log(1, "get_user_level SQL error: $DBI::errstr");
    }

    $sth->finish;
    return $level;
}

# Get user info (level, automode, greet) in this channel
sub get_user_info {
    my ($self, $nickname) = @_;
    my $info = {
        level    => 0,
        automode => 'None',
        greet    => 'None',
    };

    my $sth = $self->{dbh}->prepare(q{
        SELECT level, automode, greet
        FROM USER
        JOIN USER_CHANNEL USING (id_user)
        WHERE id_channel = ?
          AND nickname = ?
    });

    if ($sth->execute($self->{id}, $nickname)) {
        if (my $ref = $sth->fetchrow_hashref) {
            $info->{level}    = $ref->{level}    if defined $ref->{level};
            $info->{automode} = $ref->{automode} if defined $ref->{automode};
            $info->{greet}    = $ref->{greet}    if defined $ref->{greet};
        }
    } else {
        $self->{logger}->log(1, "get_user_info SQL error: $DBI::errstr");
    }

    $sth->finish;
    return $info;
}



# ------------------------
# SETTERS (with database update)
# ------------------------

# Set channel topic and update DB
sub set_topic {
    my ($self, $new_topic) = @_;
    return unless defined $new_topic;

    my $sth = $self->{dbh}->prepare("UPDATE CHANNEL SET topic=? WHERE id_channel=?");
    $sth->execute($new_topic, $self->{id});
    $self->{topic} = $new_topic;
}

# Set TMDB language and update DB
sub set_tmdb_lang {
    my ($self, $new_lang) = @_;
    return unless defined $new_lang;

    my $sth = $self->{dbh}->prepare("UPDATE CHANNEL SET tmdb_lang=? WHERE id_channel=?");
    $sth->execute($new_lang, $self->{id});
    $self->{tmdb_lang} = $new_lang;
}

# Set channel key (password) and update DB
sub set_key {
    my ($self, $new_key) = @_;
    return unless defined $new_key;
    my $sth = $self->{dbh}->prepare("UPDATE CHANNEL SET `key`=? WHERE id_channel=?");
    $sth->execute($new_key, $self->{id});
    $self->{key} = $new_key;
}

# Set channel description and update DB
sub set_description {
    my ($self, $new_description) = @_;
    return unless defined $new_description;
    my $sth = $self->{dbh}->prepare("UPDATE CHANNEL SET description=? WHERE id_channel=?");
    $sth->execute($new_description, $self->{id});
    $self->{description} = $new_description;
}

# Set channel mode (chanmode) and update DB
sub set_chanmode {
    my ($self, $new_chanmode) = @_;
    return unless defined $new_chanmode;
    my $sth = $self->{dbh}->prepare("UPDATE CHANNEL SET chanmode=? WHERE id_channel=?");
    $sth->execute($new_chanmode, $self->{id});
    $self->{chanmode} = $new_chanmode;
}

# Set auto_join flag and update DB
sub set_auto_join {
    my ($self, $new_auto_join) = @_;
    return unless defined $new_auto_join;
    my $sth = $self->{dbh}->prepare("UPDATE CHANNEL SET auto_join=? WHERE id_channel=?");
    $sth->execute($new_auto_join, $self->{id});
    $self->{auto_join} = $new_auto_join;
}

# ------------------------
# Channel Methods
# ------------------------

sub exists_in_db {
    my ($self) = @_;
    my $sth = $self->{dbh}->prepare("SELECT id FROM CHANNEL WHERE name = ?");
    $sth->execute($self->{name});
    my ($id) = $sth->fetchrow_array;
    return $id;
}

sub create_in_db {
    my ($self) = @_;
    my $sth = $self->{dbh}->prepare("INSERT INTO CHANNEL (name, description, auto_join) VALUES (?, ?, ?)");
    if ($sth->execute($self->{name}, $self->{description} || $self->{name}, 1)) {
        $self->{id} = $sth->{mysql_insertid};
        return $self->{id};
    } else {
        return undef;
    }
}

=head1 NAME

Mediabot::Channel - Objet représentant un canal IRC dans Mediabot

=head1 SYNOPSIS

    use Mediabot::Channel;

    my $channel = Mediabot::Channel->new({
        id   => 42,
        name => '#france',
        dbh  => $dbh,
        irc  => $irc,
    });

    my $name = $channel->get_name;
    $channel->set_topic("Nouveau topic");
    my $level = $channel->get_user_level('Teuk');

=head1 DESCRIPTION

Ce module fournit une interface orientée objet pour manipuler les canaux IRC gérés par Mediabot.

Il permet de récupérer ou modifier dynamiquement les propriétés stockées en base de données :
nom, topic, description, mot de passe, mode IRC, langue TMDB, auto-join, etc.

Il offre aussi des méthodes utilitaires pour gérer les utilisateurs associés à un canal.

=head1 CONSTRUCTEUR

=head2 new

    my $channel = Mediabot::Channel->new(\%args);

Crée un nouvel objet Mediabot::Channel.

Clés reconnues dans %args :

=over 4

=item * id

ID numérique du canal (id_channel)

=item * name

Nom IRC du canal (e.g. #monchan)

=item * description

Description libre du canal

=item * topic

Topic IRC courant (non synchrone)

=item * tmdb_lang

Langue TMDB liée (ex: 'fr-FR')

=item * chanmode

Modes IRC (ex: +ntk)

=item * auto_join

Booléen : rejoindre automatiquement au démarrage

=item * key

Mot de passe IRC (clé de canal)

=item * dbh

Handle DBI à la base de données MariaDB/MySQL

=item * irc

Objet IRC (Net::Async::IRC)

=back

=head1 ACCESSEURS (GETTERS)

=head2 get_id

Retourne l’ID du canal (id_channel)

=head2 get_name

Retourne le nom du canal (ex: #gwen)

=head2 get_description

Retourne la description actuelle du canal

=head2 get_topic

Retourne le topic enregistré pour ce canal

=head2 get_tmdb_lang

Retourne la langue TMDB associée (ex: en-US)

=head2 get_key

Retourne la clé IRC (mot de passe du canal)

=head2 get_auto_join

Retourne le statut auto_join (0 ou 1)

=head2 get_chanmode

Retourne le chanmode actuel (ex: +nt)

=head2 get_user_level

    my $level = $channel->get_user_level($nickname);

Retourne le niveau d’un utilisateur donné dans ce canal (via USER_CHANNEL)

=head2 get_user_info

    my $info = $channel->get_user_info($nickname);

Retourne une hashref contenant :

    {
        level    => <niveau>,
        automode => <mode>,
        greet    => <greet text>
    }

=head1 MUTATEURS (SETTERS)

Toutes les méthodes suivantes modifient à la fois l’objet *et* la base SQL.

=head2 set_topic

    $channel->set_topic("Bienvenue sur #gwen");

Met à jour le topic IRC dans la base.

=head2 set_tmdb_lang

    $channel->set_tmdb_lang("fr-FR");

Met à jour la langue TMDB associée.

=head2 set_key

    $channel->set_key("s3cret");

Met à jour la clé (mot de passe) IRC du canal.

=head2 set_description

    $channel->set_description("Canal de Gwen et Teuk");

Met à jour la description libre du canal.

=head2 set_chanmode

    $channel->set_chanmode("+ntk");

Met à jour les modes IRC du canal.

=head2 set_auto_join

    $channel->set_auto_join(1);

Définit si le bot rejoint automatiquement ce canal au lancement.

=head1 MÉTHODES CANAL / DB

=head2 exists_in_db

    my $id = $channel->exists_in_db;

Vérifie si le canal existe dans la base (par nom). Retourne l’ID s’il existe, undef sinon.

=head2 create_in_db

    my $id = $channel->create_in_db;

Crée le canal dans la base si nécessaire. Retourne l’ID du canal nouvellement inséré.

=head1 AUTEUR

Christophe L. (Teuk)

=head1 LICENCE

MIT License - Libre réutilisation avec attribution.

=cut

1;