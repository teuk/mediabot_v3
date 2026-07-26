# t/cases/768_mb579_precommit_truthfulness.t
# =============================================================================
# mb579 — derniere garde pre-commit :
#   [1] une erreur de fetch archive AVANT toute ligne garde le resultat LIVE ;
#   [2] une erreur APRES au moins une ligne archive marque le resultat tainted
#       et force live_ok=0 : les callbacks ont deja absorbe un fragment que le
#       helper generique ne peut pas annuler ;
#   [3] stats affiche first_seen meme avec zero message et ne declare pas
#       « not in database » un nick deja present dans l'historique.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Spec;

sub _slurp_768 {
    my ($p) = @_;
    open my $fh, '<:encoding(UTF-8)', $p or die "$p: $!";
    local $/;
    return <$fh>;
}

sub _sub_src_768 {
    my ($src, $name) = @_;
    my ($body) = $src =~ /(sub \Q$name\E \{.*?\n\})/s;
    return $body;
}

package Mb579::Conf;
sub new { my ($c, %v) = @_; bless \%v, $c }
sub get { my ($self, $k) = @_; return $self->{$k} }

package Mb579::Sth;
sub new {
    my ($c, %v) = @_;
    bless {
        rows      => [ @{ $v{rows} || [] } ],
        fetch_err => $v{fetch_err} || 0,
    }, $c;
}
sub execute { 1 }
sub fetchrow_hashref { my ($self) = @_; return shift @{ $self->{rows} } }
sub err    { my ($self) = @_; return $self->{fetch_err} ? 7 : 0 }
sub errstr { my ($self) = @_; return $self->{fetch_err} ? 'simulated fetch failure' : '' }
sub finish { 1 }

package Mb579::Dbh;
sub new { my ($c, %v) = @_; bless { by_table => \%v }, $c }
sub errstr { 'dbh error' }
sub prepare {
    my ($self, $sql) = @_;
    for my $table (sort { length($b) <=> length($a) } keys %{ $self->{by_table} }) {
        next unless index($sql, $table) >= 0;
        return Mb579::Sth->new(%{ $self->{by_table}{$table} });
    }
    return Mb579::Sth->new();
}

package main;

return sub {
    my ($assert) = @_;

    require Mediabot::Helpers;

    my $archive = 'archives_mediabot2.CHANNEL_LOG_ARCHIVE';
    my $bot = {
        conf => Mb579::Conf->new(
            'mysql.CHANNEL_LOG_ARCHIVE_PRESENCE_DAYS' => 7,
            'mysql.CHANNEL_LOG_ARCHIVE_CONTENT_DAYS'  => 0,
        ),
    };

    no warnings 'redefine';
    local *Mediabot::Helpers::channel_log_archive_table = sub { $archive };

    # Une erreur d'archive avant toute ligne ne contamine rien.
    {
        my @rows;
        my $dbh = Mb579::Dbh->new(
            'CHANNEL_LOG ' => {
                rows => [ { n => 1 } ],
            },
            "$archive " => {
                rows => [],
                fetch_err => 1,
            },
        );
        my $g = Mediabot::Helpers::channel_log_gather(
            $bot, $dbh, 'SELECT n FROM __CLSRC__ cl', [],
            sub { push @rows, $_[0]->{n} }, 'presence'
        );
        $assert->is($g->{live_ok}, 1,
            'archive fetch KO avant ligne: resultat LIVE exploitable');
        $assert->is($g->{tainted}, 0,
            'archive fetch KO avant ligne: resultat non contamine');
        $assert->is(join(',', @rows), '1',
            'archive fetch KO avant ligne: seule la ligne LIVE est gardee');
    }

    # Après une ligne d'archive, le callback a déjà été modifié : fail-closed.
    {
        my @rows;
        my $dbh = Mb579::Dbh->new(
            'CHANNEL_LOG ' => {
                rows => [ { n => 1 } ],
            },
            "$archive " => {
                rows => [ { n => 2 } ],
                fetch_err => 1,
            },
        );
        my $g = Mediabot::Helpers::channel_log_gather(
            $bot, $dbh, 'SELECT n FROM __CLSRC__ cl', [],
            sub { push @rows, $_[0]->{n} }, 'presence'
        );
        $assert->is($g->{live_ok}, 0,
            'archive fetch KO apres ligne: commande forcee en echec');
        $assert->is($g->{tainted}, 1,
            'archive fetch KO apres ligne: resultat marque tainted');
        $assert->is(join(',', @rows), '1,2',
            'fixture: la ligne partielle avait bien atteint le callback');
    }

    my $src = _slurp_768(File::Spec->catfile('Mediabot', 'UserCommands.pm'));
    my $stats = _sub_src_768($src, 'mbStats_ctx');
    $assert->ok(defined $stats, 'mbStats_ctx isolee');
    $assert->like(
        $stats,
        qr/first seen: \$first_seen.*?if \$first_seen;/s,
        'stats: first_seen affiche independamment de msg_count'
    );
    $assert->unlike(
        $stats,
        qr/first seen: \$first_seen.*?if \$first_seen && \$msg_count/s,
        'stats: zero message ne masque plus first_seen'
    );
    $assert->like(
        $stats,
        qr/not in database" unless \$id_user \|\| \$msg_count \|\| \$first_seen/,
        'stats: un nick deja vu n est pas declare absent'
    );
};
