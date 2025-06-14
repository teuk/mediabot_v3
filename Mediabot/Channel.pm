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

1;
