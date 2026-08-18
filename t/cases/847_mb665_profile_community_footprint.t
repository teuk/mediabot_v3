# t/cases/847_mb665_profile_community_footprint.t
# =============================================================================
# mb665 — !profil Community Footprint + durable registered-identity bridge.
# =============================================================================
use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }

{
    package Stmt847;
    sub new {
        my ($class, $kind) = @_;
        bless { kind => $kind, rows => [], pos => 0, bind => [] }, $class;
    }
    sub execute {
        my ($self, @bind) = @_;
        $self->{bind} = [@bind];
        if ($self->{kind} eq 'direct_user') {
            $self->{rows} = [];
        }
        elsif ($self->{kind} eq 'achievement_alias') {
            $self->{rows} = [ { id_user => 42 } ];
        }
        elsif ($self->{kind} eq 'footprint') {
            $self->{rows} = [ { quote_count => 28, factoid_count => 7 } ];
        }
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
        return Stmt847->new('direct_user')
            if $sql =~ /\bFROM USER\b.*\bWHERE nickname = \?/s;
        return Stmt847->new('achievement_alias')
            if $sql =~ /\bFROM ACHIEVEMENT_PROFILE\b.*\bACHIEVEMENT_IDENTITY\b/s;
        return Stmt847->new('footprint')
            if $sql =~ /\bFROM QUOTES\b.*\bFROM FACTOID\b/s;
        die "mb665-847: unexpected prepare: $sql";
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
    my $bot = {};
    my $r = Mediabot::UserCommands::_profile_community_footprint(
        $bot, $dbh, '#radiocapsule', 'te[u]k'
    );

    $assert->ok(ref($r) eq 'HASH',
        'mb665-847: footprint helper returns a result');
    $assert->is($r->{id_user}, 42,
        'mb665-847: IRC alias resolves to unique durable registered user');
    $assert->is($r->{quote_count}, 28,
        'mb665-847: registered quote contribution is returned through alias');
    $assert->is($r->{factoid_count}, 7,
        'mb665-847: factoid contribution is returned through alias');

    $assert->is(scalar @{ $dbh->{prepares} }, 3,
        'mb665-847: alias path uses direct-user, durable-identity and footprint reads');

    my $all_sql = join "\n", @{ $dbh->{prepares} };
    $assert->like($all_sql, qr/\bFROM ACHIEVEMENT_PROFILE\b/s,
        'mb665-847: existing mb646 profile graph is reused');
    $assert->like($all_sql, qr/\bACHIEVEMENT_IDENTITY\b/s,
        'mb665-847: existing mb646 alias evidence is reused');
    $assert->like($all_sql, qr/\bFROM QUOTES\b/s,
        'mb665-847: footprint reads QUOTES');
    $assert->like($all_sql, qr/\bFROM FACTOID\b/s,
        'mb665-847: footprint reads FACTOID');
    $assert->unlike($all_sql, qr/CHANNEL_LOG/s,
        'mb665-847: identity bridge adds no CHANNEL_LOG scan');
    $assert->unlike($all_sql, qr/ORDER\s+BY\s+RAND\s*\(/i,
        'mb665-847: footprint introduces no random database scan');

    my $src = slurp847('Mediabot/UserCommands.pm');
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

    $assert->like($helper, qr/LIMIT 2/s,
        'mb665-847: durable alias resolution is ambiguity-bounded');
};
