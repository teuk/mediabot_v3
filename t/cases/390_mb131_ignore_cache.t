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
    sub get_id { $_[0]{id} }
    package MB1352::User;
    sub is_authenticated { $_[0]{auth} // 1 }
    sub has_level { $_[0]{master} // 1 }
    sub nickname { 'Master' }
    sub level_description { 'User' }
    package MB1353::IRC;
    sub nick_folded { 'bot' }
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
    $bot->{channels} = {lc($target)=>bless({id=>42}, 'MB1352::Channel')};
    $bot->{irc} = bless {}, 'MB1353::IRC';
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

# MB1353: exercise writes, reads and deletion through both registered routes.
my (@wire, @audit);
sub invoke {
    my ($bot, $scope, $command, $args, $user) = @_;
    @wire = (); @audit = ();
    my $ctx = Mediabot::Context->new(bot=>$bot, nick=>'Issuer', command=>$command,
        channel=>$scope eq 'public'?'#Origin':undef, args=>$args);
    $ctx->{user} = $user || bless({}, 'MB1352::User'); $ctx->{_user_fetched} = 1;
    no warnings qw(redefine once);
    local *Mediabot::DBCommands::botNotice = sub { push @wire, [@_[1,2]]; 1 };
    local *Mediabot::DBCommands::logBot = sub { push @audit, [@_[2..$#_]]; 1 };
    local *Mediabot::DBCommands::noticeConsoleChan = sub { 1 };
    return $bot->command_registry->handler_for($command, $scope)->($ctx);
}
sub stored {
    return $_[0]{dbh}->selectall_arrayref('SELECT * FROM IGNORES ORDER BY id_ignores');
}
for my $chantype ('#', '&', '!', '+', '') {
    for my $scope (qw(public private)) {
        my $target = ($chantype || '#') . 'MiXeD';
        my $bot = fixture($target);
        $bot->{dbh}->do('INSERT INTO IGNORES VALUES(1,0,?), (2,43,?)', undef, 'Global!*@else.invalid', $mask);
        my $initial = stored($bot);
        my @channel_arg = $chantype ? ($target) : ();
        my $id = $chantype ? 42 : 0;
        my $label = $chantype ? $target : '(allchans/private)';
        my $log_channel = $chantype ? $target : undef;
        my $name = "$scope " . ($chantype || 'global');
        my @states = (ignored($bot, $target, $prefix));
        my $add = invoke($bot, $scope, 'ignore', [@channel_arg,$mask]);
        my $rows = stored($bot);
        my $added_audit = [@audit];
        my $notice_ok = @wire == 1 && $wire[0][0] eq 'Issuer'
            && $wire[0][1] =~ /Added ignore ID .*\Q$mask on $label\E/ ? 1 : 0;
        push @states, ignored($bot, $target, $prefix), ignored($bot, undef, $prefix);

        my $cache = $bot->{_ignore_cache};
        invoke($bot, $scope, 'ignore', [@channel_arg,$mask]);
        my $duplicate = [stored($bot), $bot->{_ignore_cache} == $cache ? 1 : 0, [@wire], [@audit]];
        invoke($bot, $scope, 'ignores', [@channel_arg]);
        my $list_label = $chantype ? $target : 'allchans/private';
        my @list = $chantype ? (['Issuer', "Ignores ($list_label): 1 entry found"])
            : (['Issuer', "Ignores ($list_label): 2 entries found"], ['Issuer', 'ID: 1 : Global!*@else.invalid']);
        is_deeply([$duplicate, [@wire], [@audit]],
            [[[ @$initial, [3,$id,$mask]], 1, [['Issuer', "$mask is already ignored on $label (ID 3)"]],
                [[$log_channel,'ignore',"exists $label $mask"]]],
             [@list, ['Issuer', "ID: 3 : $mask"]], [[$log_channel,'ignores',$list_label]]],
            "$name: duplicate detection and listing preserve exact scope, rows, cache and private notices");

        my $removed = invoke($bot, $scope, 'unignore', [@channel_arg,$mask]);
        push @states, ignored($bot, $target, $prefix), ignored($bot, undef, $prefix), ignored($bot, '#Other', $prefix);
        is_deeply([$add, $rows, $notice_ok, $added_audit, $removed, \@states, stored($bot), account_queries($bot), [@wire], [@audit]],
            [1, [@$initial, [3,$id,$mask]], 1, [[$log_channel,'ignore',"add $label $mask"]],
             1, [0,1,$chantype?0:1,0,0,1], $initial, [],
             [['Issuer', "Deleted ignore ID 3 $mask on $label"]], [[$log_channel,'unignore',"del $label $mask"]]],
            "$name: add/remove takes effect immediately and leaves other scopes intact");
    }
}
for my $kind (qw(unregistered missing_id unauthenticated insufficient_level)) {
    my (@got, @want);
    for my $chantype ('#', '&', '!', '+') {
        for my $scope (qw(public private)) {
            for my $command (qw(ignore ignores unignore)) {
                my $target = $chantype . 'Missing';
                my $bot = fixture('#Registered');
                $bot->{channels}{lc $target} = bless({}, 'MB1352::Channel') if $kind eq 'missing_id';
                $bot->{dbh}->do('INSERT INTO IGNORES VALUES(1,0,?)', undef, $mask);
                my $initial = stored($bot);
                my $cache = $bot->{_ignore_cache} = {sentinel=>1};
                my $user = bless {auth=>$kind ne 'unauthenticated', master=>$kind ne 'insufficient_level'}, 'MB1352::User';
                my $before = scalar @{$bot->{dbh}{private_queries}};
                invoke($bot, $scope, $command, [$target, $command eq 'ignores'?():($mask)], $user);
                my $queries = scalar(@{$bot->{dbh}{private_queries}}) - $before;
                push @got, [stored($bot), $bot->{_ignore_cache} == $cache ? 1 : 0, [@audit], [@wire], $queries];
                my $text = $kind eq 'unauthenticated'
                    ? 'You must be logged to use this command - /msg bot login username password'
                    : $kind eq 'insufficient_level' ? 'Your level does not allow you to use this command.'
                    : "Channel $target is " . ($command eq 'unignore'?'undefined':'not registered');
                push @want, [$initial, 1, [], [['Issuer', $text]], 0];
            }
        }
    }
    is_deeply(\@got, \@want, "$kind: all commands stop without SQL, global fallback or cache mutation");
}
is_deeply(\@warnings, [], 'native ignore workflows emit no warnings');
done_testing();
