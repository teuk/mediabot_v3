# t/cases/940_mb702_chanset_negative_cache_refresh.t
# =============================================================================
# MB702-B1 — a missing CHANSET_LIST entry must not be cached forever.
#
# Production incident reproduced here:
#   process starts -> lookup Wit while absent -> migration inserts Wit -> lookup again
# The second lookup must see the new row without requiring a process restart.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_940 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_940 {
    my ($src, $name) = @_;

    my $start = index($src, "sub $name");
    die "sub $name not found" if $start < 0;

    my $brace = index($src, '{', $start);
    die "opening brace for $name not found" if $brace < 0;

    my $depth = 1;
    my $pos   = $brace + 1;
    my $len   = length($src);

    while ($pos < $len && $depth > 0) {
        my $c = substr($src, $pos, 1);
        $depth++ if $c eq '{';
        $depth-- if $c eq '}';
        $pos++;
    }

    die "unterminated sub $name" if $depth != 0;
    return substr($src, $start, $pos - $start);
}

{
    package MB702::FakeLogger;
    sub new { bless { entries => [] }, shift }
    sub log { my ($self, @entry) = @_; push @{ $self->{entries} }, \@entry; return 1 }
}

{
    package MB702::FakeDBH;
    sub new {
        return bless {
            rows          => {},
            prepare_count => 0,
            execute_count => 0,
            finish_count  => 0,
        }, shift;
    }

    sub prepare {
        my ($self, $sql) = @_;
        $self->{prepare_count}++;
        return bless { dbh => $self, sql => $sql }, 'MB702::FakeSTH';
    }
}

{
    package MB702::FakeSTH;
    sub execute {
        my ($self, $value) = @_;
        $self->{dbh}{execute_count}++;
        $self->{value} = $value;
        return 1;
    }

    sub fetchrow_hashref {
        my ($self) = @_;
        my $value = $self->{value};
        return undef unless exists $self->{dbh}{rows}{$value};
        return { id_chanset_list => $self->{dbh}{rows}{$value} };
    }

    sub finish {
        my ($self) = @_;
        $self->{dbh}{finish_count}++;
        return 1;
    }
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_940(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));
    my $sub = _extract_sub_940($src, 'getIdChansetList');

    my $wrapped = "package MB702::ProductionGetIdChansetList; no warnings 'redefine'; $sub 1;";
    my $ok = eval $wrapped;
    die "cannot compile extracted getIdChansetList: $@" unless $ok;

    my $dbh = MB702::FakeDBH->new();
    my $bot = {
        dbh    => $dbh,
        logger => MB702::FakeLogger->new(),
    };

    my $first = MB702::ProductionGetIdChansetList::getIdChansetList($bot, 'Wit');
    $assert->ok(!defined $first,
        'mb702-940: first lookup sees Wit absent');
    $assert->is($dbh->{prepare_count}, 1,
        'mb702-940: first miss performs one DB lookup');
    $assert->ok(!exists $bot->{_chansetlist_cache}{wit},
        'mb702-940: missing Wit is not stored in chanset-list cache');

    # Simulate the official migration adding Wit while this same process lives.
    $dbh->{rows}{Wit} = 24;

    my $second = MB702::ProductionGetIdChansetList::getIdChansetList($bot, 'Wit');
    $assert->is($second, 24,
        'mb702-940: second lookup sees Wit added after the earlier miss');
    $assert->is($dbh->{prepare_count}, 2,
        'mb702-940: second lookup retries the DB instead of returning cached undef');
    $assert->is($bot->{_chansetlist_cache}{wit}, 24,
        'mb702-940: successful lookup is cached positively');

    delete $dbh->{rows}{Wit};

    my $third = MB702::ProductionGetIdChansetList::getIdChansetList($bot, 'Wit');
    $assert->is($third, 24,
        'mb702-940: positive cache still serves a previously resolved chanset');
    $assert->is($dbh->{prepare_count}, 2,
        'mb702-940: positive cache avoids an unnecessary third SELECT');

    $assert->is($dbh->{execute_count}, 2,
        'mb702-940: only the miss and first successful lookup execute SQL');
    $assert->is($dbh->{finish_count}, 2,
        'mb702-940: every executed statement is finished');

    my $lower = MB702::ProductionGetIdChansetList::getIdChansetList($bot, 'wit');
    $assert->is($lower, 24,
        'mb702-940: positive cache remains case-folded');
    $assert->is($dbh->{prepare_count}, 2,
        'mb702-940: case-folded positive cache avoids another SELECT');
};
