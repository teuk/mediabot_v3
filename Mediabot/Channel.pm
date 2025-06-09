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

# Set channel key and update DB
sub set_key {
    my ($self, $new_key) = @_;
    return unless defined $new_key;

    my $sth = $self->{dbh}->prepare("UPDATE CHANNEL SET `key`=? WHERE id_channel=?");
    $sth->execute($new_key, $self->{id});
    $self->{key} = $new_key;
}

1;
