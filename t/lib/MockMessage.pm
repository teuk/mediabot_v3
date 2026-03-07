package MockMessage;

# ---------------------------------------------------------------------------
# MockMessage - bouchon d'un message IRC (Net::Async::IRC)
#
# Un vrai message IRC ressemble à :
#   $message->prefix          → "nick!user@host"
#   $message->{params}[0]     → cible (channel ou nick)
#   $message->can('prefix')   → toujours vrai ici
#
# Utilisé partout où Mediabot attend un $message (mbCommandPublic,
# mbCommandPrivate, Context->new, get_user_from_message, logBot...).
# ---------------------------------------------------------------------------

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    return bless {
        prefix  => $args{prefix}  // 'testnick!testuser@testhost',
        params  => $args{params}  // [],   # params->[0] = target channel/nick
        command => $args{command} // 'PRIVMSG',
        text    => $args{text}    // '',
    }, $class;
}

# ---- Accesseurs compatibles Net::Async::IRC ----

sub prefix  { $_[0]->{prefix}  }
sub command { $_[0]->{command} }
sub text    { $_[0]->{text}    }

# Net::Async::IRC expose params comme arrayref
sub params  { $_[0]->{params}  }

# Permet "$message->can('prefix')" utilisé dans plusieurs guards
sub can {
    my ($self, $method) = @_;
    return $self->SUPER::can($method);
}

# ---- Constructeurs nommés pour les cas courants ----

# Message de channel public : !cmd arg1 arg2
sub from_channel {
    my ($class, %args) = @_;
    return $class->new(
        prefix  => $args{prefix}  // 'testnick!testuser@testhost',
        params  => [ $args{channel} // '#test' ],
        command => 'PRIVMSG',
        text    => $args{text} // '',
    );
}

# Message privé (query) : /msg botnick cmd arg1
sub from_private {
    my ($class, %args) = @_;
    my $nick = ($args{prefix} // 'testnick!testuser@testhost') =~ /^([^!]+)/ ? $1 : 'testnick';
    return $class->new(
        prefix  => $args{prefix} // 'testnick!testuser@testhost',
        params  => [ $nick ],
        command => 'PRIVMSG',
        text    => $args{text} // '',
    );
}

1;
