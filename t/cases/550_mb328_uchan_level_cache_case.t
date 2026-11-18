# t/cases/550_mb328_uchan_level_cache_case.t
# =============================================================================
# mb328 — Clé de cache de niveau canal insensible à la casse.
#
# checkUserChannelLevel() met en cache (TTL 60s) le niveau d'un user sur un
# canal, sous la clé "$id_user\x00$sChannel". channelAddUser_ctx /
# channelDelUser_ctx invalidaient cette entrée par un delete à clé EXACTE
# "$id\x00$channel". Comme les canaux IRC sont insensibles à la casse (et que le
# SQL matche en collation _ci), une population sous "#Foo" et une invalidation
# sous "#foo" ne correspondaient pas → niveau de privilège périmé jusqu'à 60s
# (un user fraîchement rétrogradé gardait son accès). mb328 normalise la clé en
# minuscules à la population ET aux invalidations.
#
# Le test :
#   1. reproduit le format de clé corrigé et prouve que #Foo et #foo donnent la
#      MÊME clé (donc l'invalidation atteint l'entrée quelle que soit la casse) ;
#   2. vérifie par scan de source que les 3 sites utilisent lc() sur le canal.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;
use Test::More;
use DBI ();
use Storable qw(dclone);
use Mediabot::Mediabot ();
use Mediabot::Context ();

sub _slurp_550 {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

# Clé telle que normalisée par le code après mb328.
sub _key { my ($id, $chan) = @_; return "$id\x00" . lc($chan); }


# --- 1. Invariant fonctionnel : casse du canal sans effet --------------
is(
    _key(42, '#Foo'),
    _key(42, '#foo'),
    'clé identique pour #Foo et #foo (invalidation atteint l\'entrée)'
);
is(
    _key(42, '#Foo'),
    _key(42, '#FOO'),
    'clé identique pour #Foo et #FOO'
);
isnt(
    _key(42, '#foo'),
    _key(42, '#bar'),
    'canaux distincts → clés distinctes'
);
isnt(
    _key(42, '#foo'),
    _key(43, '#foo'),
    'users distincts → clés distinctes'
);

# --- 2. Scan de source : lc() aux 3 sites -----------------------------
my $helpers = _slurp_550(File::Spec->catfile('.', 'Mediabot', 'Helpers.pm'));
my $chancmd = _slurp_550(File::Spec->catfile('.', 'Mediabot', 'ChannelCommands.pm'));

like(
    $helpers,
    qr/my \$cache_key = "\$id_user\\x00" \. lc\(\$sChannel\)/,
    'checkUserChannelLevel: clé de cache en lc($sChannel)'
);
like(
    $chancmd,
    qr/_uchan_level_cache\}\{"\$id_target_user\\x00" \. lc\(\$channel\)\}/,
    'channelAddUser: invalidation en lc($channel)'
);
like(
    $chancmd,
    qr/_uchan_level_cache\}\{"\$id_target\\x00" \. lc\(\$channel\)\}/,
    'channelDelUser: invalidation en lc($channel)'
);

# MB1354: level zero is a persisted membership, not a missing row.
{
    package MB1354::User;
    sub is_authenticated { $_[0]{auth} }
    sub has_level { $_[0]{admin} }
    sub id { 41 }
    sub nickname { 'issuer' }
    sub level_description { 'User' }
    package MB1354::Channel;
    sub get_id { 77 }
    package MB1354::IRC;
    sub nick_folded { 'bot' }
    package MB1354::Logger;
    sub log { 1 }
}
my @warnings;
local $SIG{__WARN__} = sub { push @warnings, @_ };
for my $case (
    ['add existing zero',      'add',0,    450,0,300,1,'existing'],
    ['admin add existing zero','add',0,      0,1,300,1,'existing'],
    ['delete existing zero',   'del',0,    450,0,0,  1,'deleted'],
    ['admin delete zero',      'del',0,      0,1,0,  1,'deleted'],
    ['add existing positive',  'add',100,  450,0,300,1,'existing'],
    ['delete positive',        'del',100,  450,0,0,  1,'deleted'],
    ['add new zero',           'add',undef,450,0,0,  1,'added'],
    ['add new positive',       'add',undef,450,0,100,1,'added'],
    # MB1355: administrator authority does not extend the channel-level range.
    ['admin add maximum',      'add',undef,0,  1,500,1,'added'],
    ['admin add over maximum', 'add',undef,0,  1,501,1,'range'],
    ['admin add high level',   'add',undef,0,  1,1000,1,'range'],
    ['admin add huge integer', 'add',undef,0,  1,'9'x400,1,'range'],
    ['owner add below own',    'add',undef,500,0,499,1,'added'],
    ['owner add own level',    'add',undef,500,0,500,1,'grant_peer'],
    ['owner add over maximum', 'add',undef,500,0,501,1,'range'],
    ['delete missing',         'del',undef,450,0,0,  1,'missing'],
    ['delete peer refused',    'del',450,  450,0,0,  1,'peer'],
    ['admin delete peer',      'del',450,  450,1,0,  1,'deleted'],
    ['add requires authority', 'add',0,    399,0,100,1,'denied'],
    ['del requires authority', 'del',0,    399,0,0,  1,'denied'],
    ['add requires login',     'add',0,    450,1,100,0,'login'],
    ['del requires login',     'del',0,    450,1,0,  0,'login'],
) {
    my ($name,$command,$initial,$issuer,$admin,$grant,$auth,$outcome) = @$case;
    for my $scope (qw(public private)) {
        my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '',
            {RaiseError=>1, PrintError=>0, AutoCommit=>1});
        $dbh->do('CREATE TABLE USER(id_user INTEGER PRIMARY KEY, nickname TEXT)');
        # Mirror the production non-null level and unique user/channel pair.
        $dbh->do("CREATE TABLE USER_CHANNEL(id_user INTEGER, id_channel INTEGER, level INTEGER NOT NULL DEFAULT 0, greet TEXT, automode TEXT NOT NULL DEFAULT 'NONE', UNIQUE(id_user,id_channel))");
        $dbh->do("INSERT INTO USER VALUES(41,'issuer'),(42,'target'),(43,'other')");
        $dbh->do('INSERT INTO USER_CHANNEL(id_user,id_channel,level) VALUES(?,?,?)', undef, @$_)
            for [41,77,$issuer], [42,78,450], [43,77,100];
        $dbh->do("INSERT INTO USER_CHANNEL VALUES(42,77,?,'kept greeting','VOICE')", undef, $initial)
            if defined $initial;
        my $before = $dbh->selectall_arrayref('SELECT * FROM USER_CHANNEL ORDER BY id_channel,id_user');
        my $expected_rows = dclone($before);
        @$expected_rows = grep { !($_->[0]==42 && $_->[1]==77) } @$expected_rows if $outcome eq 'deleted';
        if ($outcome eq 'added') {
            push @$expected_rows, [42,77,$grant,undef,'NONE'];
            @$expected_rows = sort {$a->[1]<=>$b->[1] || $a->[0]<=>$b->[0]} @$expected_rows;
        }
        my $bot = Mediabot->new({}); $bot->{dbh}=$dbh;
        $bot->{irc}=bless {},'MB1354::IRC'; $bot->{logger}=bless {},'MB1354::Logger';
        $bot->{channels}={'#test'=>bless({},'MB1354::Channel')};
        $bot->{_uchan_level_cache}={"42\0#test"=>{ts=>time,val=>$initial//0},
            "42\0#other"=>{ts=>time,val=>450},"43\0#test"=>{ts=>time,val=>100}};
        my $expected_cache=dclone($bot->{_uchan_level_cache});
        delete $expected_cache->{"42\0#test"} if $outcome eq 'added' || $outcome eq 'deleted';
        my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Issuer',command=>$command,
            channel=>$scope eq 'public'?'#TeSt':undef,
            args=>[$scope eq 'private'?('#TeSt'):(), 'target', $command eq 'add'?($grant):()]);
        $ctx->{user}=bless {auth=>$auth,admin=>$admin},'MB1354::User'; $ctx->{_user_fetched}=1;
        my (@wire,@audit);
        no warnings qw(redefine once);
        local *Mediabot::ChannelCommands::botNotice=sub {push @wire,[@_[1,2]];1};
        local *Mediabot::ChannelCommands::logBot=sub {push @audit,[@_[2..$#_]];1};
        local *Mediabot::ChannelCommands::noticeConsoleChan=sub {1};
        eval {$bot->command_registry->handler_for($command,$scope)->($ctx);1};
        my $error=$@;
        my %notices=(existing=>'User target is already on #TeSt with level '.($initial//0),
            deleted=>'User target removed from #TeSt', added=>"Added target to #TeSt at level $grant",
            missing=>'User target does not appear to have access on #TeSt',
            peer=>"You can't del a user with a level equal or greater than yours",
            range=>'Cannot set user access higher than 500.',
            grant_peer=>"You can't assign a level equal or higher than yours.",
            denied=>'Your level does not allow you to use this command.',
            login=>'You must be logged to use this command - /msg bot login username password');
        my $expected_audit=$outcome eq 'added'?[['#TeSt','add','#TeSt','target',$grant]]
            :$outcome eq 'deleted'?[['#TeSt','del','#TeSt','target']]:[];
        is_deeply([$error,$dbh->selectall_arrayref('SELECT * FROM USER_CHANNEL ORDER BY id_channel,id_user'),
                $bot->{_uchan_level_cache},\@wire,\@audit],
            ['', $expected_rows,$expected_cache,[['Issuer',$notices{$outcome}]],$expected_audit],
            "$scope $name: stored membership, metadata, cache, notice and audit remain consistent");
    }
}
is_deeply(\@warnings,[],'native add/del membership boundaries emit no warnings');
done_testing();
