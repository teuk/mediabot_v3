package MockBot;

# ---------------------------------------------------------------------------
# MockBot - bouchon de l'objet Mediabot principal
#
# Simule l'interface de $mediabot telle qu'utilisée par :
#   - mbCommandPublic() / mbCommandPrivate()
#   - les sous-routines _ctx (via Context)
#   - botPrivmsg(), botNotice(), logBot(), noticeConsoleChan()
#
# Les réponses IRC sont capturées dans :
#   $bot->{replies}   → [ { type => 'privmsg'|'notice', to => ..., text => ... } ]
#
# Ce tableau est purgeable entre deux tests via $bot->reset_replies().
#
# La vraie connexion MariaDB est optionnelle : si un $dbh est fourni,
# les commandes qui en ont besoin fonctionneront normalement.
# Sinon, get_user_from_message() retourne le $mock_user configuré.
# ---------------------------------------------------------------------------

use strict;
use warnings;
use Encode qw(encode decode);

# Modules Mediabot réels (on les charge depuis le répertoire racine du projet)
use Mediabot::Context;
use Mediabot::Command;
use Mediabot::Log;

# MockAuth inline — stub de Mediabot::Auth pour les tests
{
    package MockAuth;
    sub new { bless { always_pass => $_[1] // 0 }, $_[0] }
    # verify_credentials($id_user, $login, $password)
    # Par défaut refuse tout. Passer always_pass=>1 pour tester les login réussis.
    sub verify_credentials {
        my ($self, $id_user, $login, $password) = @_;
        return $self->{always_pass} ? 1 : 0;
    }
}

# MockChannelBan inline — stub minimal de Mediabot::ChannelBan
{
    package MockChannelBan;
    sub new { bless {}, $_[0] }
    sub add_ban       { return (undef, 'MockChannelBan: not implemented') }
    sub list_active_bans { return () }
    sub mark_removed  { return (0, 'MockChannelBan: not implemented') }
    sub expired_bans  { return () }
    sub validate_mask { return undef }   # undef = valid
    sub normalize_mask { return $_[1] }
    sub mask_from_hostmask { return undef }
    sub parse_duration { return (0, 'permanent', undef) }
    sub parse_ban_level { return ($_[2], undef) }
    sub looks_like_duration { return 0 }
    sub looks_like_level    { return 0 }
    sub min_ban_level { return 75 }
}

# MockConf inline : émule Mediabot::Conf sans Config::Simple
{
    package MockConf;
    sub new {
        my ($class, $hash) = @_;
        return bless { _conf => $hash // {} }, $class;
    }
    sub get { $_[0]->{_conf}{ $_[1] } }
    sub set { $_[0]->{_conf}{ $_[1] } = $_[2] }
}

sub new {
    my ($class, %args) = @_;

    # Logger silencieux par défaut (level -1 = rien), ou verbeux si demandé
    my $debug_level = $args{debug_level} // -1;
    my $logger = Mediabot::Log->new(debug_level => $debug_level);

    # Conf minimale indispensable pour mbCommandPublic et botPrivmsg
    my $conf = MockConf->new({
        'main.MAIN_PROG_CMD_CHAR'        => $args{cmd_char}    // '!',
        'main.MAIN_PROG_LIVE'            => 0,
        'main.MAIN_PROG_NAME'            => 'MockBot',
        'main.MAIN_PROG_INITIAL_TRIGGER' => 0,
    });

    # IRC bouchonné (MockIRC ou objet fourni)
    my $irc = $args{irc} // do {
        require MockIRC;
        MockIRC->new(nick => $args{botnick} // 'mediabot');
    };

    my $self = bless {
        conf    => $conf,
        logger  => $logger,
        irc     => $irc,
        dbh     => $args{dbh},          # optionnel : vrai DBI handle
        replies => [],                  # capture des réponses IRC
        _mock_user => $args{mock_user}, # MockUser par défaut si pas de dbh
        Quit    => 0,
        # Stubs indispensables pour les commandes ban/channel/auth
        channels    => $args{channels}    // {},
        channel_ban => $args{channel_ban} // MockChannelBan->new(),
        auth        => $args{auth}        // MockAuth->new(),
    }, $class;

    return $self;
}

# ---------------------------------------------------------------------------
# Capture des sorties IRC
# (remplacent les vraies botPrivmsg / botNotice qui enverraient sur IRC)
# ---------------------------------------------------------------------------

sub botPrivmsg {
    my ($self, $to, $msg) = @_;
    return unless defined $to && defined $msg;
    push @{ $self->{replies} }, { type => 'privmsg', to => $to, text => $msg };
}

sub botNotice {
    my ($self, $target, $text) = @_;
    return unless defined $target && $target ne '' && defined $text && $text ne '';
    push @{ $self->{replies} }, { type => 'notice', to => $target, text => $text };
}

# ---------------------------------------------------------------------------
# Stubs des méthodes internes appelées par les _ctx subs
# ---------------------------------------------------------------------------

sub noticeConsoleChan {
    my ($self, $msg) = @_;
    # silencieux dans les tests
}

sub logBot {
    my ($self, @args) = @_;
    # silencieux dans les tests
}

sub logBotAction {
    my ($self, @args) = @_;
}

sub checkAntiFlood {
    return 0;  # jamais de flood en test
}

sub getIdChansetList {
    return undef;  # aucun chanset actif par défaut
}

sub getIdChannelSet {
    return undef;
}

sub isIgnored {
    return 0;  # personne n'est ignoré
}

sub get_hailo {
    return undef;
}

sub is_hailo_excluded_nick {
    return 0;
}

sub getChannelOwner {
    return undef;
}

sub getReplyTarget {
    my ($self, $message, $nick) = @_;
    my $target = $message->{params}[0] // '';
    return ($target =~ /^#/) ? $target : $nick;
}

sub _dbg_auth_snapshot { }
sub _ensure_logged_in_state { }

# ---------------------------------------------------------------------------
# get_user_from_message : retourne le mock_user si pas de vraie DB,
# sinon délègue à la vraie implémentation (importée depuis Mediabot.pm)
# ---------------------------------------------------------------------------

sub get_user_from_message {
    my ($self, $message) = @_;
    return $self->{_mock_user};
}

# Setter pour changer l'utilisateur courant entre deux tests
sub set_mock_user {
    my ($self, $user) = @_;
    $self->{_mock_user} = $user;
}

# ---------------------------------------------------------------------------
# Helpers pour les assertions dans les tests
# ---------------------------------------------------------------------------

# Retourne toutes les réponses capturées
sub replies { @{ $_[0]->{replies} } }

# Retourne uniquement les privmsgs
sub privmsgs {
    my ($self) = @_;
    return grep { $_->{type} eq 'privmsg' } @{ $self->{replies} };
}

# Retourne uniquement les notices
sub notices {
    my ($self) = @_;
    return grep { $_->{type} eq 'notice' } @{ $self->{replies} };
}

# Retourne le texte de la première réponse (quel que soit le type)
sub first_reply_text {
    my ($self) = @_;
    my @r = $self->replies;
    return @r ? $r[0]->{text} : undef;
}

# Vrai si au moins une réponse contient ce texte (regexp ou littéral)
sub replied_with {
    my ($self, $pattern) = @_;
    for my $r ($self->replies) {
        return 1 if $r->{text} =~ /$pattern/;
    }
    return 0;
}

# Compte le nombre total de réponses
sub count_replies {
    my ($self) = @_;
    return scalar @{ $self->{replies} };
}

# Vrai si aucune réponse ne matche ce pattern
sub replied_none {
    my ($self, $pattern) = @_;
    for my $r ($self->replies) {
        return 0 if $r->{text} =~ /$pattern/;
    }
    return 1;
}

# Remet les captures à zéro entre deux tests
sub reset_replies {
    my ($self) = @_;
    $self->{replies} = [];
    $self->{irc}->reset_capture() if $self->{irc}->can('reset_capture');
}

# Permet d'injecter un vrai Mediabot::ChannelBan dans les tests avancés
sub set_channel_ban {
    my ($self, $cb) = @_;
    $self->{channel_ban} = $cb;
}

# Permet d'injecter des channels mockés
sub set_channels {
    my ($self, $channels) = @_;
    $self->{channels} = $channels;
}

1;
