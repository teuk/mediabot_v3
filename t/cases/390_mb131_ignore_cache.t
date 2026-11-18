use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use lib "$Bin/../..";
use DBI ();
use Mediabot::Mediabot ();
use Mediabot::Context ();
use Mediabot::Helpers ();

my $root = File::Spec->catdir($Bin, '..', '..');
my $helpers_file = File::Spec->catfile($root, 'Mediabot', 'Helpers.pm');
open my $hfh, '<', $helpers_file or die "cannot open Helpers.pm: $!";
my $helpers = do { local $/; <$hfh> };
close $hfh;

ok($helpers =~ /\$self->\{_ignore_cache\}/, 'isIgnored uses _ignore_cache');
ok($helpers =~ /my \$ttl = 30/, 'isIgnored cache TTL is 30 seconds');
ok($helpers =~ /SELECT hostmask FROM IGNORES WHERE id_channel = 0/, 'global ignores query still present');
ok($helpers =~ /JOIN CHANNEL ON CHANNEL\.id_channel = IGNORES\.id_channel WHERE CHANNEL\.name = \?/, 'channel ignores query still present');
ok($helpers =~ /hostmask_matches/, 'matching still uses Mediabot::Auth hostmask matcher');
ok($helpers =~ /chan\\x00\$channel_key/, 'channel cache key is lower-cased and namespaced');

my $db_file = File::Spec->catfile($root, 'Mediabot', 'DBCommands.pm');
open my $dfh, '<', $db_file or die "cannot open DBCommands.pm: $!";
my $db = do { local $/; <$dfh> };
close $dfh;

my $invalidations = () = ($db =~ /delete \$self->\{_ignore_cache\}; # mb131-B4/g);
ok($invalidations >= 2, 'ignore/unignore invalidate _ignore_cache');

my $ch_file = File::Spec->catfile($root, 'Mediabot', 'ChannelCommands.pm');
open my $cfh, '<', $ch_file or die "cannot open ChannelCommands.pm: $!";
my $ch = do { local $/; <$cfh> };
close $cfh;

ok($ch =~ /delete \$self->\{_ignore_cache\}; # mb131-B4: purge may remove channel-scoped IGNORES rows/,
    'purgeChannel_ctx invalidates _ignore_cache');

# MB1352: use native Auth matching, not a permissive fake matcher.
{
    package MB1352::DBI; our @ISA = ('DBI');
    package MB1352::DBI::db; our @ISA = ('DBI::db');
    sub prepare {
        my ($db, $sql, @rest) = @_;
        push @{$db->{private_queries}}, $sql;
        # Portable SQLite equivalent of the production one-row DELETE.
        $sql = 'DELETE FROM IGNORES WHERE id_ignores IN (SELECT id_ignores FROM IGNORES WHERE id_channel = ? AND hostmask = ? LIMIT 1)'
            if $sql eq 'DELETE FROM IGNORES WHERE id_channel = ? AND hostmask = ? LIMIT 1';
        return $db->SUPER::prepare($sql, @rest);
    }
    package MB1352::DBI::st; our @ISA = ('DBI::st');
    package MB1352::Channel;
    sub get_id { 42 }
    package MB1352::User;
    sub is_authenticated { 1 }
    sub has_level { 1 }
    package MB1352::Message;
    sub prefix { $_[0]{prefix} }
    package MB1352::Logger;
    sub log { push @{$_[0]{lines}}, [@_[1,2]]; 1 }
}
$INC{'MB1352/DBI.pm'} = __FILE__;
my $mask = 'Target!*@*.example.org';
my $prefix = 'TaRgEt!~ident@sub.example.org';
my @warnings;
local $SIG{__WARN__} = sub { push @warnings, @_ };

sub fixture {
    my ($target) = @_;
    my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '',
        {RootClass=>'MB1352::DBI', RaiseError=>1, PrintError=>0, AutoCommit=>1});
    $dbh->do('CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY, name TEXT COLLATE NOCASE)');
    $dbh->do('CREATE TABLE IGNORES(id_ignores INTEGER PRIMARY KEY, id_channel INTEGER, hostmask TEXT)');
    # An ignored sender need not have any registered bot account.
    $dbh->do('CREATE TABLE USER(id_user INTEGER, nickname TEXT, username TEXT, auth TEXT)');
    $dbh->do('CREATE TABLE USER_HOSTMASK(id_user_hostmask INTEGER, id_user INTEGER, hostmask TEXT)');
    $dbh->do('INSERT INTO CHANNEL VALUES(42,?), (43,?)', undef, $target, '#Other');
    my $bot = Mediabot->new({});
    $bot->{dbh} = $dbh;
    $bot->{logger} = bless {lines=>[]}, 'MB1352::Logger';
    $bot->{channels} = {lc($target)=>bless({}, 'MB1352::Channel')};
    return $bot;
}
sub ignored {
    my ($bot, $target, $sender) = @_;
    return Mediabot::Helpers::isIgnored($bot,
        bless({prefix=>$sender}, 'MB1352::Message'), $target, 'Target', 'hello');
}
sub account_queries {
    my ($bot) = @_;
    return [grep { /\bFROM USER(?:_HOSTMASK)?\b/ } @{$bot->{dbh}{private_queries}}];
}

for my $kind (qw(global channel)) {
    for my $chantype ('#', '&', '!', '+') {
        my $target = $chantype . 'MiXeD';
        my $bot = fixture($target);
        $bot->{dbh}->do('INSERT INTO IGNORES VALUES(1,?,?)', undef, $kind eq 'global'?0:42, $mask);
        my @got = (
            ignored($bot, $target, $prefix),
            ignored($bot, lc($target), lc($prefix)),
            ignored($bot, $target, 'Target!ident@sub.example.org.evil'),
            ignored($bot, $target, 'Other!ident@sub.example.org'),
            ignored($bot, '#Other', $prefix),
            ignored($bot, undef, $prefix),
            ignored($bot, 'Issuer', $prefix),
            Mediabot::Helpers::isIgnored($bot, undef, $target, 'Target', 'hello'),
        );
        my $global = $kind eq 'global' ? 1 : 0;
        is_deeply(\@got, [1,1,0,0,$global,$global,$global,0],
            "$kind $chantype: unregistered senders match only the mask and intended message scope");
        is_deeply(account_queries($bot), [], "$kind $chantype: mask matching performs no account lookup");
        my $reads = scalar @{$bot->{dbh}{private_queries}};
        ignored($bot, $target, $prefix);
        is(scalar @{$bot->{dbh}{private_queries}}, $reads, "$kind $chantype: warm ignore cache avoids SQL");
        ok(grep({ $_->[1] =~ /\[IGNORED\]/ } @{$bot->{logger}{lines}}),
            "$kind $chantype: a confirmed ignore retains its operational log");
    }
}

# Real add/delete commands must immediately refresh a primed native filter.
for my $kind (qw(global channel)) {
    for my $scope (qw(public private)) {
        my $bot = fixture('#MiXeD');
        my @channel_arg = $kind eq 'channel' ? ('#MiXeD') : ();
        my $invoke = sub {
            my ($command) = @_;
            my $ctx = Mediabot::Context->new(bot=>$bot, nick=>'Issuer', command=>$command,
                channel=>$scope eq 'public'?'#Origin':undef, args=>[@channel_arg,$mask]);
            $ctx->{user} = bless {}, 'MB1352::User'; $ctx->{_user_fetched} = 1;
            no warnings qw(redefine once);
            local *Mediabot::DBCommands::botNotice = sub { 1 };
            local *Mediabot::DBCommands::logBot = sub { 1 };
            return $bot->command_registry->handler_for($command, $scope)->($ctx);
        };
        my @states = (ignored($bot, '#MiXeD', $prefix));
        $invoke->('ignore');
        push @states, ignored($bot, '#MiXeD', $prefix), ignored($bot, undef, $prefix);
        $invoke->('unignore');
        push @states, ignored($bot, '#MiXeD', $prefix), ignored($bot, undef, $prefix);
        is_deeply([\@states, $bot->{dbh}->selectall_arrayref('SELECT * FROM IGNORES'), account_queries($bot)],
            [[0,1,$kind eq 'global'?1:0,0,0], [], []],
            "$scope $kind: add/remove invalidates cached results and changes native matching immediately");
    }
}
is_deeply(\@warnings, [], 'native ignore workflows emit no warnings');
done_testing();
