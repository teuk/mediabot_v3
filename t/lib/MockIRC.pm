package MockIRC;

# ---------------------------------------------------------------------------
# MockIRC - bouchon léger de Net::Async::IRC pour les tests unitaires
#
# Intercept :
#   - send_message()  → capture dans @sent_messages
#   - do_NOTICE()     → capture dans @sent_notices
#   - nick_folded()   → retourne le nick configuré (défaut : "mediabot")
#   - do_PRIVMSG()    → capture dans @sent_privmsgs (au cas où)
# ---------------------------------------------------------------------------

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    return bless {
        nick          => $args{nick} // 'mediabot',
        sent_messages => [],
        sent_notices  => [],
        sent_privmsgs => [],
    }, $class;
}

# ---- Accesseurs ----

sub nick_folded { $_[0]->{nick} }

# ---- Capture des envois IRC ----

sub send_message {
    my ($self, $cmd, $prefix, @params) = @_;
    push @{ $self->{sent_messages} }, {
        command => $cmd,
        prefix  => $prefix,
        params  => \@params,
    };
}

sub do_NOTICE {
    my ($self, %args) = @_;
    push @{ $self->{sent_notices} }, {
        target => $args{target},
        text   => $args{text},
    };
}

sub do_PRIVMSG {
    my ($self, %args) = @_;
    push @{ $self->{sent_privmsgs} }, {
        target => $args{target},
        text   => $args{text},
    };
}

# ---- Helpers pour assertions dans les tests ----

# Retourne tous les messages envoyés (toutes méthodes confondues)
sub all_sent {
    my ($self) = @_;
    return (
        @{ $self->{sent_messages} },
        @{ $self->{sent_notices}  },
        @{ $self->{sent_privmsgs} },
    );
}

# Remet les compteurs à zéro entre deux tests
sub reset_capture {
    my ($self) = @_;
    $self->{sent_messages} = [];
    $self->{sent_notices}  = [];
    $self->{sent_privmsgs} = [];
}

1;
