package MockUser;

# ---------------------------------------------------------------------------
# MockUser - bouchon de Mediabot::User pour les tests
#
# Implémente la même interface publique que Mediabot::User :
#   id(), nickname(), is_authenticated(), has_level(), level_description()
#
# Usage dans les tests :
#   my $owner = MockUser->new(nick => 'teuk',   level => 'Owner',   auth => 1);
#   my $master = MockUser->new(nick => 'buddy', level => 'Master',  auth => 1);
#   my $anon   = MockUser->new(nick => 'rando', level => 'User',    auth => 0);
# ---------------------------------------------------------------------------

use strict;
use warnings;

# Hiérarchie identique à Mediabot::User::has_level()
my %LEVEL_RANK = (
    owner         => 0,
    master        => 1,
    administrator => 2,
    user          => 3,
);

sub new {
    my ($class, %args) = @_;
    return bless {
        id       => $args{id}    // 1,
        nick     => $args{nick}  // 'testnick',
        level    => $args{level} // 'User',
        auth     => $args{auth}  // 0,
        hostmask => $args{hostmask} // 'testnick!testuser@testhost',
    }, $class;
}

# ---- Interface Mediabot::User ----

sub id                { $_[0]->{id}    }
sub nickname          { $_[0]->{nick}  }
sub username          { $_[0]->{nick}  }
sub level_description { $_[0]->{level} }
sub level             { $_[0]->{level} }
sub is_authenticated  { $_[0]->{auth} ? 1 : 0 }
sub hostmasks         { $_[0]->{hostmask} }

sub has_level {
    my ($self, $required) = @_;
    return 0 unless defined $required && $required ne '';

    my $cur_lc = lc($self->{level});
    my $req_lc = lc($required);

    return 0 unless exists $LEVEL_RANK{$cur_lc} && exists $LEVEL_RANK{$req_lc};
    return ($LEVEL_RANK{$cur_lc} <= $LEVEL_RANK{$req_lc}) ? 1 : 0;
}

# Suffisant pour que Context->require_auth ne plante pas
sub maybe_autologin { return 0 }

1;
