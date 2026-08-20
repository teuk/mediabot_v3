# t/cases/850_mb668_community_achievements.t
# =============================================================================
# mb668 — community contribution achievements.
# Real QUOTES/FACTOID state drives progress after successful write events.
# =============================================================================

use strict;
use warnings;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use File::Temp qw(tempdir);

my $DIR = tempdir(CLEANUP => 1);

{
    package Log850;
    sub new { bless { lines => [] }, shift }
    sub log { push @{ $_[0]{lines} }, [ @_[1 .. $#_] ]; 1 }
}

{
    package Stmt850;
    sub new {
        my ($class, $row) = @_;
        bless { row => $row, binds => [], fetched => 0 }, $class;
    }
    sub execute {
        my ($self, @bind) = @_;
        $self->{binds} = [ @bind ];
        return 1;
    }
    sub fetchrow_hashref {
        my ($self) = @_;
        return undef if $self->{fetched}++;
        return { %{ $self->{row} } };
    }
    sub finish { 1 }
}

{
    package DBH850;
    sub new {
        my ($class, $row) = @_;
        bless { row => $row, prepares => [], stmt => undef }, $class;
    }
    sub can {
        my ($self, $method) = @_;
        return sub { 1 } if $method eq 'prepare';
        return UNIVERSAL::can($self, $method);
    }
    sub prepare {
        my ($self, $sql) = @_;
        push @{ $self->{prepares} }, $sql;
        $self->{stmt} = Stmt850->new($self->{row});
        return $self->{stmt};
    }
}

{
    package Ach850;
    our @ISA = ('Mediabot::Achievements');

    sub set_progress {
        my ($self, $kind, $nick, $channel, $value) = @_;
        push @{ $self->{progress_calls} }, [ $kind, $nick, $channel, $value ];
        return $value;
    }

    sub unlock {
        my ($self, $nick, $channel, $id) = @_;
        push @{ $self->{unlock_calls} }, [ $nick, $channel, $id ];
        return 1;
    }
}

sub slurp850 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

sub sub_src850 {
    my ($src, $name) = @_;
    my $start = index($src, "sub $name {");
    return undef if $start < 0;
    my $next = index($src, "\nsub ", $start + 5);
    $next = length($src) if $next < 0;
    return substr($src, $start, $next - $start);
}

return sub {
    my ($assert) = @_;

    require Mediabot::Achievements;

    my $defs = Mediabot::Achievements::list_definitions();

    my %expect = (
        archivist        => [ 'quotes_contributed',   10, 'uncommon', 'Archivist' ],
        master_archivist => [ 'quotes_contributed',   50, 'rare',     'Master Archivist' ],
        lorekeeper       => [ 'factoids_contributed', 10, 'uncommon', 'Lorekeeper' ],
        encyclopedist    => [ 'factoids_contributed', 50, 'rare',     'Encyclopedist' ],
        curator          => [ 'community_curator',    10, 'epic',     'Curator' ],
    );

    for my $id (sort keys %expect) {
        my ($kind, $threshold, $rarity, $name) = @{ $expect{$id} };
        $assert->ok(ref($defs->{$id}) eq 'HASH',
            "mb668-850: catalogue contains $id");
        $assert->is($defs->{$id}{check_on}, 'community',
            "mb668-850: $id uses community trigger");
        $assert->is($defs->{$id}{progress_kind}, $kind,
            "mb668-850: $id progress kind");
        $assert->is($defs->{$id}{threshold}, $threshold,
            "mb668-850: $id threshold");
        $assert->is($defs->{$id}{rarity}, $rarity,
            "mb668-850: $id rarity");
        $assert->is($defs->{$id}{name}, $name,
            "mb668-850: $id display name");
    }

    # 53 quotes + 12 factoids unlock both quote levels, Lorekeeper and Curator.
    my $dbh = DBH850->new({ quote_count => 53, factoid_count => 12 });
    my $A = Ach850->new(path => "$DIR/a.json", logger => Log850->new);
    $A->{bot} = { dbh => $dbh };
    $A->{_channel_ids}{'#c'} = 7;

    my $result = $A->check_community_contributions('Te[u]K', '#c', 42);

    $assert->ok(ref($result) eq 'HASH',
        'mb668-850: community check returns its observed state');
    $assert->is($result->{quotes}, 53,
        'mb668-850: real quote count returned');
    $assert->is($result->{factoids}, 12,
        'mb668-850: real factoid count returned');
    $assert->is($result->{curator}, 12,
        'mb668-850: Curator progress is the lower of both contribution counts');

    $assert->is(scalar @{ $dbh->{prepares} }, 1,
        'mb668-850: one consolidated read derives all community progress');
    my $sql = $dbh->{prepares}[0];
    $assert->like($sql, qr/\bFROM QUOTES\b/s,
        'mb668-850: query reads QUOTES');
    $assert->like($sql, qr/\bFROM FACTOID\b/s,
        'mb668-850: query reads FACTOID');
    $assert->unlike($sql, qr/CHANNEL_LOG/s,
        'mb668-850: no channel-history scan is introduced');
    $assert->unlike($sql, qr/ORDER\s+BY\s+RAND\s*\(/i,
        'mb668-850: no random database scan is introduced');

    $assert->is(
        join(',', map { $_->[0] . '=' . $_->[3] } @{ $A->{progress_calls} || [] }),
        'quotes_contributed=53,factoids_contributed=12,community_curator=12',
        'mb668-850: all three monotonic progress values come from DB state'
    );

    my @unlock = map { $_->[2] } @{ $A->{unlock_calls} || [] };
    $assert->is(join(',', @unlock),
        'archivist,master_archivist,lorekeeper,curator',
        'mb668-850: only thresholds actually reached are unlocked');

    # An anonymous/legacy caller cannot claim the pooled id_user=0 quote corpus.
    # Factoids remain attributable by created_by_nick when created_by is NULL.
    my $dbh2 = DBH850->new({ quote_count => 0, factoid_count => 65 });
    my $B = Ach850->new(path => "$DIR/b.json", logger => Log850->new);
    $B->{bot} = { dbh => $dbh2 };
    $B->{_channel_ids}{'#c'} = 7;

    my $r2 = $B->check_community_contributions('guest', '#c', 0);
    $assert->is($r2->{quotes}, 0,
        'mb668-850: id_user=0 is not treated as an attributable quote owner');
    $assert->is($r2->{factoids}, 65,
        'mb668-850: nick-attributed legacy factoids remain measurable');
    my @unlock2 = map { $_->[2] } @{ $B->{unlock_calls} || [] };
    $assert->is(join(',', @unlock2), 'lorekeeper,encyclopedist',
        'mb668-850: factoid ladder can unlock independently');

    # Verify the two natural write triggers, without executing unrelated command
    # plumbing in this focused contract test.
    my $quote_src = slurp850('Mediabot/Quotes.pm');
    my $quote_add = sub_src850($quote_src, 'mbQuoteAdd');
    $assert->ok(defined $quote_add,
        'mb668-850: quote add source found');
    $assert->like($quote_add,
        qr/check_community_contributions\(\s*\$sNick,\s*\$sChannel,\s*\$id_user\s*\)/s,
        'mb668-850: successful quote add checks community achievements with registered id');
    $assert->like($quote_add,
        qr/if\s*\(\$self->\{achievements\}\).*?eval\s*\{.*?check_community_contributions/s,
        'mb668-850: quote achievement hook is optional and failure-isolated');

    my $quote_id_pos = index($quote_add, 'my $id_inserted = $self->{dbh}->last_insert_id');
    my $quote_hook_pos = index($quote_add, 'check_community_contributions');
    $assert->ok(
        $quote_id_pos >= 0 && $quote_hook_pos > $quote_id_pos,
        'mb668-850: quote id is captured before Achievement writes can replace last_insert_id'
    );

    my $uc_src = slurp850('Mediabot/CommunityState.pm');
    my $learn = sub_src850($uc_src, 'mbLearn_ctx');
    $assert->ok(defined $learn,
        'mb668-850: learn source found');
    $assert->like($learn,
        qr/check_community_contributions\(\s*\$nick,\s*\$channel,\s*\$uid\s*\)/s,
        'mb668-850: successful factoid learn checks community achievements');
    $assert->like($learn,
        qr/if\s*\(\$self->\{achievements\}\).*?eval\s*\{.*?check_community_contributions/s,
        'mb668-850: factoid achievement hook is optional and failure-isolated');

    # Keep the public catalogue accounting explicit after adding five visible
    # achievements: 40 total, 3 secret, 37 visible.
    my @all = keys %$defs;
    my @hidden = grep { $defs->{$_}{hidden} } @all;
    $assert->is(scalar @all, 40,
        'mb668-850: catalogue now contains 40 achievements');
    $assert->is(scalar @hidden, 3,
        'mb668-850: MB668 does not add hidden achievements');
};
