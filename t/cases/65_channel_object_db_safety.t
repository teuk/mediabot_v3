# t/cases/65_channel_object_db_safety.t
# =============================================================================
# Static regression checks for Mediabot::Channel DB safety.
# =============================================================================

use strict;
use warnings;

BEGIN {
    use FindBin qw($Bin);
    unshift @INC, "$Bin/../lib";
    unshift @INC, "$Bin/../..";
}

use File::Spec;

sub _slurp_channel_object_safety {
    my ($path) = @_;

    open my $fh, '<:encoding(UTF-8)', $path or die "cannot read $path: $!";
    local $/;
    return <$fh>;
}

sub _extract_sub_channel_object_safety {
    my ($src, $name) = @_;

    my $start = index($src, "sub $name");
    die "sub $name not found" if $start < 0;

    my $brace = index($src, "{", $start);
    die "opening brace for $name not found" if $brace < 0;

    my $depth      = 0;
    my $in_single  = 0;
    my $in_double  = 0;
    my $in_comment = 0;
    my $escape     = 0;

    for (my $i = $brace; $i < length($src); $i++) {
        my $c = substr($src, $i, 1);

        if ($in_comment) {
            $in_comment = 0 if $c eq "\n";
            next;
        }

        if ($in_single) {
            if ($c eq "\\" && !$escape) {
                $escape = 1;
                next;
            }

            if ($c eq "'" && !$escape) {
                $in_single = 0;
            }

            $escape = 0;
            next;
        }

        if ($in_double) {
            if ($c eq "\\" && !$escape) {
                $escape = 1;
                next;
            }

            if ($c eq '"' && !$escape) {
                $in_double = 0;
            }

            $escape = 0;
            next;
        }

        if ($c eq "#") {
            $in_comment = 1;
            next;
        }

        if ($c eq "'") {
            $in_single = 1;
            next;
        }

        if ($c eq '"') {
            $in_double = 1;
            next;
        }

        if ($c eq "{") {
            $depth++;
        }
        elsif ($c eq "}") {
            $depth--;

            if ($depth == 0) {
                return substr($src, $start, $i - $start + 1);
            }
        }
    }

    die "end of sub $name not found";
}

return sub {
    my ($assert) = @_;

    my $src = _slurp_channel_object_safety(File::Spec->catfile('.', 'Mediabot', 'Channel.pm'));

    $assert->ok(
        $src =~ /sub _execute_update/,
        'Channel.pm has shared _execute_update helper'
    );

    my $helper = _extract_sub_channel_object_safety($src, '_execute_update');

    $assert->ok(
        $helper =~ /unless \(\$sth\)/,
        '_execute_update handles prepare failure'
    );

    $assert->ok(
        $helper =~ /SQL prepare error/,
        '_execute_update logs prepare failure'
    );

    $assert->ok(
        $helper =~ /unless \(\$sth->execute\(\@\{\$binds \|\| \[\]\}\)\)/,
        '_execute_update handles execute failure'
    );

    $assert->ok(
        $helper =~ /\$sth->finish;\s*return 0;/s,
        '_execute_update finishes statement on execute failure'
    );

    for my $setter (qw(set_topic set_tmdb_lang set_timezone set_key set_description set_chanmode set_auto_join)) {
        my $func = _extract_sub_channel_object_safety($src, $setter);

        $assert->ok(
            $func =~ /_execute_update/,
            "$setter uses shared safe update helper"
        );

        $assert->ok(
            $func =~ /return \$ok \? 1 : 0;/,
            "$setter returns explicit success boolean"
        );
    }

    for my $getter (qw(get_user_level get_user_info exists_in_db create_in_db)) {
        my $func = _extract_sub_channel_object_safety($src, $getter);

        $assert->ok(
            $func =~ /unless \(\$sth\)/,
            "$getter handles prepare failure"
        );

        $assert->ok(
            $func =~ /SQL prepare error/,
            "$getter logs prepare failure"
        );

        $assert->ok(
            $func =~ /unless \(\$sth->execute/,
            "$getter handles execute failure"
        );

        $assert->ok(
            $func =~ /\$sth->finish;\s*return/s,
            "$getter finishes statement before returning on execute failure"
        );
    }

    my $create = _extract_sub_channel_object_safety($src, 'create_in_db');
    $assert->ok(
        $create =~ /\$self->\{dbh\}->last_insert_id/,
        'create_in_db uses dbh last_insert_id after statement finish'
    );
    # MB918: real cached channels, factory paths and native DBI/SQLite handles.
    # A private file DB substitutes the server; only reconnect establishment,
    # registration/IRC/log sinks and Context authorization are controlled.
    require JSON::PP;
    my $probe = <<'MB918_NATIVE';
use strict;
use warnings;
use utf8;
use DBI;
use File::Temp qw(tempdir);
use JSON::PP;
use Mediabot::DB;
use Mediabot::Channel;
use Mediabot::Mediabot;
use Mediabot::ChannelCommands;
{
 package MB918::Log;
 sub log { push @{$_[0]{events}}, [$_[1],$_[2]]; 1 }
 package MB918::DB;
 our @ISA=('Mediabot::DB');
 sub _connect {
  my($s)=@_;$s->{connects}++;
  return undef if $s->{unavailable};
  return $s->{dbh}=DBI->connect('dbi:SQLite:dbname='.$s->{path},'','',{RaiseError=>0,PrintError=>0,AutoCommit=>1});
 }
 package MB918::Bot;
 our @ISA=('Mediabot');
 sub setup_channel_nicklist_timers { 1 }
 package MB918::Message;
 sub prefix { 'Alice!user@fixture' }
 package MB918::Ctx;
 sub bot {$_[0]{bot}} sub nick {'Alice'} sub message {bless {},'MB918::Message'}
 sub args {['#new','Alice']} sub require_level {$_[0]{checks}++;1}
}
sub fixture {
 my $dir=tempdir(CLEANUP=>1);
 my $log=bless {events=>[]},'MB918::Log';
 my $db=bless {path=>"$dir/test.sqlite",logger=>$log},'MB918::DB';
 my $dbh=$db->_connect;
 $dbh->do(q{CREATE TABLE CHANNEL(id_channel INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT UNIQUE,description TEXT,topic TEXT,tmdb_lang TEXT,timezone TEXT,"key" TEXT,auto_join INTEGER,chanmode TEXT)});
 $dbh->do(q{CREATE TABLE USER(id_user INTEGER PRIMARY KEY,nickname TEXT)});
 $dbh->do(q{CREATE TABLE USER_CHANNEL(id_user INTEGER,id_channel INTEGER,level INTEGER,automode TEXT,greet TEXT)});
 $dbh->do(q{INSERT INTO CHANNEL VALUES(1,'#test','old description','old topic','en','UTC','oldkey',1,'+nt')});
 $dbh->do(q{INSERT INTO USER VALUES(1,'Alice')});
 $dbh->do(q{INSERT INTO USER_CHANNEL VALUES(1,1,450,'op','hello')});
 my $b=bless {db=>$db,dbh=>$dbh,channels=>{},logger=>$log},'MB918::Bot';
 return ($b,$dir);
}
no warnings qw(redefine once);
local *Mediabot::ChannelCommands::getIdUser=sub {1};
local *Mediabot::ChannelCommands::registerChannel=sub {1};
local *Mediabot::ChannelCommands::joinChannel=sub {1};
local *Mediabot::ChannelCommands::botNotice=sub {push @{$_[0]{notices}},$_[2];1};
local *Mediabot::ChannelCommands::logBot=sub {1};
local *Mediabot::ChannelCommands::noticeConsoleChan=sub {1};
sub channel {
 my($b,$factory)=@_;
 if($factory eq 'populate'){$b->populateChannels;return $b->{channels}{'#test'}}
 if($factory eq 'lookup'){return Mediabot::ChannelCommands::get_channel_by_name($b,'#test')}
 my $ctx=bless {bot=>$b},'MB918::Ctx';
 Mediabot::ChannelCommands::addChannel_ctx($ctx);
 $b->{dbh}->do(q{INSERT INTO USER_CHANNEL VALUES(1,2,450,'op','hello')});
 return $b->{channels}{'#new'};
}
sub reconnect {
 my($b)=@_;
 $b->{dbh}->disconnect;
 $b->{dbh}=$b->{db}->ensure_connected;
 die 'fixture reconnect failed' unless $b->{dbh};
}
my %out;
my @setters=(['set_topic','new topic','topic'],['set_tmdb_lang','fr-FR','tmdb_lang'],['set_timezone','Europe/Paris','timezone'],['set_key','newkey','key'],['set_description','new description','description'],['set_chanmode','+stn-k','chanmode'],['set_auto_join',0,'auto_join']);
for my $factory(qw(populate lookup add)){
 my($b,$dir)=fixture();my$c=channel($b,$factory);die 'missing channel' unless$c;
 reconnect($b);
 my @ok=map {my($m,$v)=@$_;$c->$m($v)?1:0}@setters;
 my $row=$b->{dbh}->selectrow_hashref(q{SELECT topic,tmdb_lang,timezone,"key",description,chanmode,auto_join FROM CHANNEL WHERE id_channel=?},undef,$c->get_id);
 $out{writes}{$factory}={ok=>\@ok,row=>$row};
 $b->{dbh}->disconnect;
}
for my $factory(qw(populate lookup add)){
 for my $kind(qw(level info id)){
  my($b,$dir)=fixture();my$c=channel($b,$factory);reconnect($b);
  $out{reads}{$factory}{$kind}=$kind eq 'level' ? $c->get_user_level('Alice')
   : $kind eq 'info' ? $c->get_user_info('Alice') : $c->exists_in_db;
  $b->{dbh}->disconnect;
 }
 my($b,$dir)=fixture();my$c=channel($b,$factory);reconnect($b);
 my $before=$b->{dbh}->selectrow_array('SELECT COUNT(*) FROM CHANNEL');
 $c->{name}='#insert';delete$c->{id};
 my $id=$c->create_in_db;
 $out{creates}{$factory}={id=>$id,count=>$b->{dbh}->selectrow_array('SELECT COUNT(*) FROM CHANNEL')-$before};
 $b->{dbh}->disconnect;
}
# Reconnect initiated by the channel itself rather than by the bot first.
{
 my($b,$dir)=fixture();my$c=channel($b,'populate');$b->{dbh}->disconnect;
 $out{self_reconnect}={ok=>$c->set_topic('recovered')?1:0,connects=>$b->{db}{connects},topic=>scalar($b->{db}{dbh}->selectrow_array('SELECT topic FROM CHANNEL WHERE id_channel=1'))};
 $b->{db}{dbh}->disconnect;
}
# The owner being unavailable must clear an old object's handle and fail closed.
for my $factory(qw(populate lookup add)){
 my($b,$dir)=fixture();my$c=channel($b,$factory);$b->{dbh}->disconnect;$b->{db}{unavailable}=1;
 my @warnings;local$SIG{__WARN__}=sub {push @warnings,@_};
 my $ok=$c->set_topic('should not appear');
 my $level=$c->get_user_level('Alice');my$info=$c->get_user_info('Alice');
 my$id=$c->exists_in_db;$c->{name}='#unavailable';delete$c->{id};my$created=$c->create_in_db;
 $out{unavailable}{$factory}={ok=>$ok?1:0,level=>$level,info=>$info,id=>$id,created=>$created,cleared=>!defined($c->{dbh})?1:0,warnings=>\@warnings};
}
# Historical dbh-only objects keep working without any owner or reconnect policy.
{
 my($b,$dir)=fixture();my$c=Mediabot::Channel->new({id=>1,name=>'#test',dbh=>$b->{dbh},logger=>$b->{logger}});
 my@ok=map{my($m,$v)=@$_;$c->$m($v)?1:0}@setters;
 $out{legacy}={ok=>\@ok,level=>$c->get_user_level('Alice'),info=>$c->get_user_info('Alice'),id=>$c->exists_in_db};
 $b->{dbh}->disconnect;
}
print JSON::PP->new->canonical->utf8->encode(\%out);
MB918_NATIVE
    open my $native, '-|', $^X, '-I.', '-It/lib', '-e', $probe
        or die "start channel reconnect probe: $!";
    my $output = do { local $/; <$native> };
    close $native;
    $assert->is($? >> 8, 0, 'native channel reconnect probe completes');
    my $result = JSON::PP::decode_json($output);
    my $json = JSON::PP->new->canonical;
    for my $factory (qw(populate lookup add)) {
        $assert->is($json->encode($result->{writes}{$factory}), $json->encode({
            ok => [(1) x 7], row => {
                topic => 'new topic', tmdb_lang => 'fr-FR', timezone => 'Europe/Paris',
                key => 'newkey', description => 'new description', chanmode => '+stn-k', auto_join => 0,
            },
        }), "$factory: seven channel setters follow the reconnected DBI handle");
    }
    $assert->is($json->encode($result->{reads}), $json->encode({
        map { $_ => {level => 450, info => {level => 450, automode => 'op', greet => 'hello'},
            id => $_ eq 'add' ? 2 : 1} } qw(populate lookup add)
    }), 'fresh cached objects recover user rights, user information and channel identity independently');
    $assert->is($json->encode($result->{creates}), $json->encode({
        map { $_ => {id => $_ eq 'add' ? 3 : 2, count => 1} } qw(populate lookup add)
    }), 'channel creation and insert identity use the reconnected handle');
    $assert->is($json->encode($result->{self_reconnect}),
        $json->encode({ok => 1, connects => 2, topic => 'recovered'}),
        'the channel can initiate the existing connection-owner recovery itself');
    $assert->is($json->encode($result->{unavailable}), $json->encode({
        map { $_ => {ok => 0, level => 0, info => {level => 0, automode => 'None', greet => 'None'},
            id => undef, created => undef, cleared => 1, warnings => []} } qw(populate lookup add)
    }), 'failed reconnect clears the stale handle and retains conservative returns');
    $assert->is($json->encode($result->{legacy}), $json->encode({
        ok => [(1) x 7], level => 450, info => {level => 450, automode => 'op', greet => 'hello'}, id => 1,
    }), 'historical dbh-only callers retain their native query and setter behavior');

};
