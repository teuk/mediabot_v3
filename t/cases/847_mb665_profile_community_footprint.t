# t/cases/847_mb665_profile_community_footprint.t
# =============================================================================
# mb665/mb669 — !profil Community Footprint through the durable identity API.
# =============================================================================
use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

{
    package Stmt847;
    sub new { bless { rows => [], pos => 0, bind => [] }, shift }
    sub execute {
        my ($self, @bind) = @_;
        $self->{bind} = [@bind];
        $self->{rows} = [ { quote_count => 28, factoid_count => 7 } ];
        $self->{pos} = 0;
        return 1;
    }
    sub fetchrow_hashref {
        my ($self) = @_;
        return undef if $self->{pos} >= @{ $self->{rows} };
        return $self->{rows}[ $self->{pos}++ ];
    }
    sub finish { 1 }
}

{
    package DBH847;
    sub new { bless { prepares => [] }, shift }
    sub prepare {
        my ($self, $sql) = @_;
        push @{ $self->{prepares} }, $sql;
        return Stmt847->new if $sql =~ /\bFROM QUOTES\b.*\bFROM FACTOID\b/s;
        die "mb665-847: unexpected prepare: $sql";
    }
}

{
    package Ach847;
    sub new { bless { calls => [] }, shift }
    sub resolve_registered_user {
        my ($self, $channel, $nick) = @_;
        push @{ $self->{calls} }, [$channel, $nick];
        return {
            status          => 'ok',
            source          => 'durable_alias',
            id_user         => 42,
            registered_nick => 'fixture_user',
        };
    }
}

sub slurp847 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "$path: $!";
    local $/;
    return <$fh>;
}

sub sub_src847 {
    my ($src, $name) = @_;
    my $start = index($src, "sub $name {");
    return undef if $start < 0;
    my $next = index($src, "\nsub ", $start + 5);
    $next = length($src) if $next < 0;
    return substr($src, $start, $next - $start);
}

return sub {
    my ($assert) = @_;

    require Mediabot::UserCommands;

    my $dbh = DBH847->new;
    my $ach = Ach847->new;
    my $bot = { achievements => $ach };
    my $r = Mediabot::UserCommands::_profile_community_footprint(
        $bot, $dbh, '#mb665-fixture', 'alias_fixture'
    );

    $assert->ok(ref($r) eq 'HASH',
        'mb665-847: footprint helper returns a result');
    $assert->is($r->{id_user}, 42,
        'mb665-847: community footprint consumes resolved registered USER id');
    $assert->is($r->{quote_count}, 28,
        'mb665-847: registered quote contribution is returned through alias');
    $assert->is($r->{factoid_count}, 7,
        'mb665-847: factoid contribution is returned through alias');

    $assert->is(scalar @{ $ach->{calls} }, 1,
        'mb665-847: identity API is called exactly once');
    $assert->is($ach->{calls}[0][0], '#mb665-fixture',
        'mb665-847: identity API receives the current channel');
    $assert->is($ach->{calls}[0][1], 'alias_fixture',
        'mb665-847: identity API receives the profile target nick');

    $assert->is(scalar @{ $dbh->{prepares} }, 1,
        'mb665-847: UserCommands owns only the bounded footprint read');

    my $all_sql = join "\n", @{ $dbh->{prepares} };
    $assert->like($all_sql, qr/\bFROM QUOTES\b/s,
        'mb665-847: footprint reads QUOTES');
    $assert->like($all_sql, qr/\bFROM FACTOID\b/s,
        'mb665-847: footprint reads FACTOID');
    $assert->unlike($all_sql, qr/ACHIEVEMENT_(?:PROFILE|IDENTITY)/s,
        'mb665-847: UserCommands no longer reads Achievement identity tables');
    $assert->unlike($all_sql, qr/CHANNEL_LOG/s,
        'mb665-847: identity bridge adds no CHANNEL_LOG scan');
    $assert->unlike($all_sql, qr/ORDER\s+BY\s+RAND\s*\(/i,
        'mb665-847: footprint introduces no random database scan');

    my $src = slurp847('Mediabot/SocialHistory.pm');
    my $profile = sub_src847($src, 'mbProfil_ctx');
    my $helper  = sub_src847($src, '_profile_community_footprint');

    $assert->ok(defined $profile && defined $helper,
        'mb665-847: helper and profile source remain isolated');

    my $gathers = () = $profile =~ /channel_log_gather\(/g;
    my $prepares = () = $profile =~ /\$dbh->prepare\(/g;
    $assert->is($gathers, 3,
        'mb665-847: !profil still owns exactly three CHANNEL_LOG gathers');
    $assert->is($prepares, 2,
        'mb665-847: !profil still owns only karma + trivia prepares');
    $assert->like($profile,
        qr/_profile_community_footprint\(\$self,\s*\$dbh,\s*\$channel,\s*\$target\)/,
        'mb665-847: !profil delegates identity-aware community read');
    $assert->like($profile, qr/community:.*quote_count.*factoid_count/s,
        'mb665-847: !profil renders the compact community line');

    $assert->like($helper, qr/resolve_registered_user\(\$channel,\s*\$target\)/,
        'mb665-847: footprint uses the public durable identity API');
    $assert->unlike($helper, qr/ACHIEVEMENT_(?:PROFILE|IDENTITY)/,
        'mb665-847: footprint has no private Achievement schema knowledge');
};
