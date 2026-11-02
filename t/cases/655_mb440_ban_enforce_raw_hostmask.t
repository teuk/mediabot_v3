use strict;
use warnings;
use utf8;
use Test::More;
use DBI;
use Mediabot::ChannelBan;

my @warnings;
local $SIG{__WARN__}=sub {push @warnings,@_};
my $db=DBI->connect('dbi:SQLite:dbname=:memory:','','',{
    RaiseError=>1,PrintError=>0,sqlite_unicode=>1});
my $bans=Mediabot::ChannelBan->new(dbh=>$db);
my $raw='spammer!~sp@host.com';
my $normal=$bans->mask_from_hostmask($raw);
is($bans->_mask_matches_irc('spammer!*@host.com',$raw),1,
    'native nickname ban matches the real joining hostmask');
is($bans->_mask_matches_irc('spammer!*@host.com',$normal),0,
    'normalizing away the joining nickname would still lose a nickname-specific ban');
is_deeply([map {$bans->_mask_matches_irc('*!*sp@host.com',$_)} ($raw,$normal)],[1,1],
    'native user/host bans retain their real and normalized mask behavior');

my @cases=(
    ['N[ic]k!*@host.example','n[IC]K!user@HOST.EXAMPLE',1],
    ['N[ic]k!*@host.example','nick!user@host.example',0],
    ['nick!id\\ent@host.(test)+com','NICK!ID\\ENT@HOST.(TEST)+COM',1],
    ['nick!id@host.com','nick!id@hostXcom',0],
    ['?ser!*@host','Éser!user@HOST',1],
    ['?ser!*@host','ser!user@host',0],
    ['?ser!*@host','XXser!user@host',0],
    ['ÉCOLE!*@host','école!user@HOST',1],
    ['ß!*@host','SS!user@host',1],
    ['***nick**!*@**host***','NICK!id@HOST',1],
    ['spammer!*@host.com','xspammer!id@host.com',0],
    ['spammer!*@host.com','spammer!id@host.com.evil',0],
    ['', '',1],['*','',1],['?','',0],[undef,'nick!id@host',0],['*',undef,0],
);
is_deeply([map {$bans->_mask_matches_irc($_->[0],$_->[1])} @cases],
    [map {$_->[2]} @cases],
    'literal regex punctuation, question marks, star runs, anchoring, Unicode case and empty inputs keep their semantics');

# A generous interruption budget prevents a regressed matcher hanging the
# suite. Completion is checked separately: the legacy matcher catches alarm's
# exception and returns a false non-match, which must not count as success.
sub bounded655 {
    my ($code)=@_;my ($value,$expired,$error)=(undef,0,'');
    local $SIG{ALRM}=sub {$expired=1;die "matcher interruption budget\n"};
    my $ok=eval {alarm 5;$value=$code->();1};
    $error=$@ unless $ok;
    alarm 0;
    return [$expired,$error,$value];
}
my $host='a'x70;
my $slow='*!*@'.('*a'x25).'b';
$db->do(q{CREATE TABLE CHANNEL_BAN (
    id_channel_ban INTEGER PRIMARY KEY,id_channel INTEGER,mask TEXT,ban_level INTEGER,
    reason TEXT,created_by INTEGER,created_by_nick TEXT,created_at TEXT,expires_at TEXT,
    active INTEGER,source TEXT)});
for my $r ([10,1,'*!*sp@'.$host,1],[30,1,'spammer!*@'.$host,1],
    [40,1,$slow,1],[50,1,'spammer!*@'.$host,0],[60,2,'spammer!*@'.$host,1]) {
    $db->do('INSERT INTO CHANNEL_BAN(id_channel_ban,id_channel,mask,active) VALUES(?,?,?,?)',undef,@$r);
}
my $before=$db->selectall_arrayref('SELECT * FROM CHANNEL_BAN ORDER BY id_channel_ban');
my $lookup=bounded655(sub {$bans->active_ban_for_mask(1,'spammer!~sp@'.$host)});
my $other=$bans->active_ban_for_mask(2,'spammer!~sp@'.$host);
is_deeply([$lookup->[0],$lookup->[1],$lookup->[2]{id_channel_ban},$other->{id_channel_ban},
    $bans->active_ban_for_mask(99,$raw),
    $db->selectall_arrayref('SELECT * FROM CHANNEL_BAN ORDER BY id_channel_ban')],
    [0,'',30,60,undef,$before],
    'native SQLite lookup skips the hostile non-match, keeps channel/active/latest precedence and never changes stored bans');
my $hard=bounded655(sub {$bans->_mask_matches_irc($slow,'nick!ident@'.$host)});
my $positive=$hard->[0] ? undef : $bans->_mask_matches_irc($slow,'nick!ident@'.$host.'b');
is_deeply([$hard->[0],$hard->[1],$hard->[2],$positive],[0,'',0,1],
    'repeated-star late failure completes without interruption while its positive variant still matches');

# Retain the original JOIN wiring guard, consolidating its four source pins.
# Loading mediabot.pl would start the bot; this does not pretend to run JOIN.
open my $fh,'<:encoding(UTF-8)','mediabot.pl' or die $!;
my $source=do {local $/;<$fh>};close $fh;
$source =~ s/^\s*#.*$//mg;
ok($source =~ /my \$raw_hostmask = "\$sNick!\$sIdent\\\@\$sHost";/
    && $source =~ /active_ban_for_mask\(\$id_channel, \$raw_hostmask\)/
    && $source !~ /active_ban_for_mask\(\$id_channel, \$norm_mask\)/
    && $source =~ /'\+b', \$norm_mask/ && !@warnings,
    'JOIN wiring still checks the raw hostmask and sets its normalized ban; native checks emit no warnings');
$db->disconnect;
done_testing;
