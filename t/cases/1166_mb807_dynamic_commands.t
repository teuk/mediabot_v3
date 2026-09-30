use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use Mediabot::DBCommands;
use Mediabot::ChannelCommands;
use Mediabot::Context;
use Mediabot::CommandRegistry;
use MockUser;
use MockMessage;

{
    package MB807Log;
    sub log { push @{$_[0]{lines}}, [@_[1..$#_]] }
    package MB807Bot;
    sub get_user_from_message { $_[0]{user} }
    sub commands { $_[0]{registry} }
    sub botNotice { push @{$_[0]{sent}}, ['notice', @_[1,2]] }
    sub botPrivmsg { push @{$_[0]{sent}}, ['privmsg', @_[1,2]] }
    package MB807DB;
    sub new { bless { rows => {}, cats => {general => 10}, users => {teuk => 1, ami => 2}, sql => [], handles => [], next_id => 1 }, $_[0] }
    sub prepare {
        my ($db, $sql) = @_;
        $sql =~ s/\s+/ /g; $sql =~ s/^ | $//g;
        return if $db->{prepare_fail} && $sql =~ $db->{prepare_fail};
        my $sth = bless { db => $db, sql => $sql, result => [] }, 'MB807STH';
        push @{$db->{handles}}, $sth;
        return $sth;
    }
    sub by_id { my ($db,$id) = @_; return (grep { $_->{id_public_commands} == $id } values %{$db->{rows}})[0] }
    package MB807STH;
    sub execute {
        my ($sth, @v) = @_;
        my ($db,$sql) = @{$sth}{qw(db sql)};
        push @{$db->{sql}}, [$sql, @v];
        return if $db->{execute_fail} && $sql =~ $db->{execute_fail};
        my $rows = $db->{rows};
        if ($sql =~ /^SELECT .* FROM PUBLIC_COMMANDS_CATEGORY WHERE description = \?/) {
            $sth->{result} = exists $db->{cats}{lc $v[0]} ? [{id_public_commands_category => $db->{cats}{lc $v[0]}}] : [];
        } elsif ($sql =~ /^INSERT INTO PUBLIC_COMMANDS_CATEGORY /) {
            $db->{cats}{lc $v[0]} = 11;
        } elsif ($sql =~ /^INSERT INTO PUBLIC_COMMANDS /) {
            die 'duplicate' if exists $rows->{lc $v[2]};
            $rows->{lc $v[2]} = {id_public_commands => $db->{next_id}++, id_user => $v[0], id_public_commands_category => $v[1], command => $v[2], description => $v[3], action => $v[4], hits => 0, active => 1, creation_date => '2026-09-30'};
        } elsif ($sql =~ /^SELECT .* FROM PUBLIC_COMMANDS(?: PC)? .*WHERE (?:PC\.)?command = \?/ || $sql =~ /^SELECT .* FROM PUBLIC_COMMANDS WHERE command = \?/) {
            my $row = $rows->{lc $v[0]};
            $row = undef if $sql =~ /AND active = 1/ && $row && !$row->{active};
            if ($row && $sql =~ /JOIN USER/) {
                die 'system owner requires LEFT JOIN' unless $sql =~ /LEFT JOIN/ || defined $row->{id_user};
            }
            $sth->{result} = $row ? [{%$row, category => 'general', old_user => $row->{id_user}, old_nick => defined($row->{id_user}) ? 'teuk' : undef}] : [];
        } elsif ($sql =~ /^SELECT action FROM PUBLIC_COMMANDS WHERE id_public_commands = \?/) {
            my $row = $db->by_id($v[0]); $sth->{result} = $row ? [{%$row}] : [];
        } elsif ($sql =~ /^UPDATE PUBLIC_COMMANDS SET id_public_commands_category=\?, action=\?/) {
            my $row = $db->by_id($v[2]); @{$row}{qw(id_public_commands_category action)} = @v[0,1];
        } elsif ($sql =~ /^UPDATE PUBLIC_COMMANDS SET command = \?/) {
            my $row = $db->by_id($v[1]); delete $rows->{lc $row->{command}};
            $row->{command} = $v[0]; $rows->{lc $v[0]} = $row;
        } elsif ($sql =~ /^UPDATE PUBLIC_COMMANDS SET active = \?/) {
            $db->by_id($v[1])->{active} = $v[0];
        } elsif ($sql =~ /^UPDATE PUBLIC_COMMANDS SET hits=hits\+1/) {
            $db->by_id($v[0])->{hits}++;
        } elsif ($sql =~ /^UPDATE PUBLIC_COMMANDS SET id_user=\?/) {
            $db->by_id($v[1])->{id_user} = $v[0];
        } elsif ($sql =~ /^UPDATE PUBLIC_COMMANDS SET id_public_commands_category = \? WHERE command = \?/) {
            $rows->{lc $v[1]}->{id_public_commands_category} = $v[0];
        } elsif ($sql =~ /^DELETE FROM PUBLIC_COMMANDS WHERE id_public_commands=\?/) {
            my $row = $db->by_id($v[0]); delete $rows->{lc $row->{command}};
        } elsif ($sql =~ /^SELECT id_user FROM USER WHERE nickname = \?/) {
            $sth->{result} = exists $db->{users}{$v[0]} ? [{id_user => $db->{users}{$v[0]}}] : [];
        } elsif ($sql =~ /^SELECT nickname FROM USER WHERE id_user=\?/) {
            $sth->{result} = [{nickname => 'teuk'}];
        } elsif ($sql =~ /^SELECT command, hits FROM PUBLIC_COMMANDS WHERE \(command LIKE/) {
            my $kw = $v[0]; $kw =~ s/^%|%$//g; $kw =~ s/!(.)/$1/g;
            $sth->{result} = [map { {%$_} } grep { index($_->{command}, $kw)>=0 || index($_->{action}, $kw)>=0 } values %$rows];
        } else { die "Unexpected SQL: $sql" }
        return 1;
    }
    sub fetchrow_hashref { shift @{$_[0]{result}} }
    sub fetchrow_arrayref { my $row = shift @{$_[0]{result}}; $row ? [values %$row] : undef }
    sub finish { $_[0]{finished} = 1; 1 }
}

use Test::More;
binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';
for my $handle (Test::More->builder->output, Test::More->builder->failure_output, Test::More->builder->todo_output) {
    binmode $handle, ':encoding(UTF-8)';
}
{
    package MB807Assert;
    sub ok { shift; goto &Test::More::ok }
    sub is { shift; goto &Test::More::is }
    sub like { shift; goto &Test::More::like }
}

(sub {
    my ($a) = @_;
    no warnings 'redefine';
    local *Mediabot::DBCommands::botNotice = sub { $_[0]->botNotice(@_[1,2]) };
    local *Mediabot::DBCommands::botPrivmsg = sub { $_[0]->botPrivmsg(@_[1,2]) };
    local *Mediabot::DBCommands::botAction = sub { push @{$_[0]{sent}}, ['action', @_[1,2]] };
    local *Mediabot::DBCommands::logBot = sub { };
    local *Mediabot::DBCommands::noticeConsoleChan = sub { };
    local *Mediabot::ChannelCommands::botNotice = sub { $_[0]->botNotice(@_[1,2]) };
    local *Mediabot::ChannelCommands::noticeConsoleChan = sub { };
    local *Mediabot::ChannelCommands::logBot = sub { };
    my $random_nicks = 0;
    local *Mediabot::Helpers::getRandomNick = sub { $random_nicks++; 'ami' };
    my $db = MB807DB->new;
    my $user = MockUser->new(nick=>'teuk', id=>1, auth=>1, level=>'Administrator');
    my $bot = bless {dbh=>$db, logger=>bless({},'MB807Log'), user=>$user, sent=>[], registry=>Mediabot::CommandRegistry->new}, 'MB807Bot';
    my $message = MockMessage->from_channel(prefix=>'Teuk!u@example.invalid', channel=>'#teuk', text=>'test');
    my $run = sub {
        my ($handler, @args) = @_;
        $bot->{sent} = [];
        my $ctx = Mediabot::Context->new(bot=>$bot, nick=>'Teuk', channel=>'#teuk', message=>$message, args=>\@args);
        no strict 'refs'; &{"Mediabot::DBCommands::$handler"}($ctx);
        return join('\n', map { $_->[2] } @{$bot->{sent}});
    };
    $run->('mbDbAddCommand_ctx', "cafe\x{301}", 'action', 'general', 'fait un café super bon pour %n !');
    my $row = $db->{rows}{'café'};
    $a->ok($row, 'reported café command is created');
    $a->is($row->{command}, 'café', 'stored command normalised to NFC');
    $a->is($row->{action}, 'ACTION %c fait un café super bon pour %n !', 'action prefix and UTF-8 body preserved');
    $bot->{sent}=[];
    $a->is(mbDbCommand($bot,$message,'#teuk','Teuk',"cafe\x{301}"),1,'decomposed runtime lookup handled');
    $a->is(join('|', @{$bot->{sent}[0]}), 'action|#teuk|fait un café super bon pour Teuk !', 'runtime sends one café action');
    $a->is($row->{hits},1,'valid call counted once');
    $bot->{sent}=[];
    mbDbCommand($bot,$message,'#teuk','Teuk','café','Alice','%on');
    $a->like($bot->{sent}[0][2],qr/Alice %on !$/,'runtime user arguments are never reinterpreted');
    $a->like($run->('mbDbAddCommand_ctx','café','message','general','duplicate'),qr/already exists/,'duplicate rejected');
    for my $name ('help','addcmd','bad name','a' x 65) {
        my $count = @{$db->{sql}};
        $run->('mbDbAddCommand_ctx',$name,'message','general','test');
        $a->is(scalar(@{$db->{sql}}),$count,'invalid/reserved new names refused before SQL');
    }
    $bot->{registry}->register(name=>'custom', source=>'public', aliases=>['aliascustom'], handler=>sub{});
    for my $name ('custom','aliascustom') {
        $a->like($run->('mbDbAddCommand_ctx',$name,'message','general','test'),qr/reserved/,'plugin and alias collision refused');
    }
    for my $text ('x'x245,'%rand{6,1}',"bad\nline") {
        my $count = @{$db->{sql}};
        $run->('mbDbModCommand_ctx','café','message','general',$text);
        $a->is(scalar(@{$db->{sql}}),$count,'modcmd validates before SQL');
        $a->like($row->{action},qr/^ACTION /,'invalid modcmd leaves action intact');
        $run->('mbDbAddCommand_ctx','new','message','general',$text);
        $a->ok(!exists $db->{rows}{new},'invalid addcmd creates nothing');
    }
    $row->{id_user}=2;
    $a->like($run->('mbDbModCommand_ctx','café','message','general','denied'),qr/belongs to another/,'administrator cannot modify another owner');
    $a->like($run->('mbDbRemCommand_ctx','café'),qr/belongs to another/,'administrator cannot delete another owner');
    $a->like($run->('mbDbMvCommand_ctx','café','thé'),qr/level/,'rename still requires Master');
    $user->{level}='Master';
    $run->('mbDbModCommand_ctx','café','message','general','%target% : %rand{1,1} %choose{oui|non}');
    $a->is($row->{action},'PRIVMSG %c %target% : %rand{1,1} %choose{oui|non}','Master can modify another owner and use richer template');
    $run->('mbDbHoldCommand_ctx','café'); $a->is($row->{active},0,'bare holdcmd preserves disable behaviour');
    $bot->{sent}=[];
    $a->is(mbDbCommand($bot,$message,'#teuk','Teuk','café'),0,'held command never executes');
    $a->is(scalar @{$bot->{sent}},0,'held command sends nothing');
    my $hits=$row->{hits}; my $queries=@{$db->{sql}};
    $a->like($run->('mbDbTestCommand_ctx',"cafe\x{301}",'Alice'),qr/Preview café \[PRIVMSG, on hold\]: Alice : 1 (?:oui|non)/,'private preview works for held command');
    $a->is($row->{hits},$hits,'preview does not change hits');
    $a->is(scalar(@{$db->{sql}}),$queries+1,'preview only reads one stored command');
    $a->is($bot->{sent}[0][0],'notice','preview sent by notice to caller');
    $run->('mbDbHoldCommand_ctx','café','off'); $a->is($row->{active},1,'holdcmd off reactivates');
    $run->('mbDbHoldCommand_ctx','café','toggle'); $a->is($row->{active},0,'toggle deactivates');
    $run->('mbDbHoldCommand_ctx','café','toggle'); $a->is($row->{active},1,'toggle reactivates');
    $a->like($run->('mbDbHoldCommand_ctx','café','maybe'),qr/Syntax/,'unknown hold mode refused');
    for my $name ('help','bad name','x'x65) {
        $run->('mbDbMvCommand_ctx','café',$name); $a->ok(exists $db->{rows}{'café'},'invalid rename preserves command');
    }
    $run->('mbDbMvCommand_ctx',"cafe\x{301}",'thé'); $a->ok(exists $db->{rows}{'thé'} && !exists $db->{rows}{'café'},'rename between Unicode names works');
    $row=$db->{rows}{'thé'};
    $a->like($run->('mbDbShowCommand_ctx',"the\x{301}"),qr/thé|the\x{301}/,'showcmd normalises lookup');
    $a->like($run->('mbDbSearchCommand_ctx','thé'),qr/thé/,'searchcmd finds command name without matching body');
    $run->('mbDbSearchCommand_ctx','a_!%','two', '9');
    $a->is(join('|',@{$db->{sql}[-1]}[1..3]),'%a!_!!!% two%|%a!_!!!% two%|9','search escapes wildcard and multiword input for both fields');
    $run->('mbDbAddCategoryCommand_ctx',"ete\x{301}"); $a->ok(exists $db->{cats}{'eté'},'Unicode category normalised');
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Teuk',channel=>'#teuk',message=>$message,args=>['eté',"the\x{301}"]);
    Mediabot::ChannelCommands::mbDbChangeCategoryCommand_ctx($ctx);
    $a->is($row->{id_public_commands_category},11,'chcatcmd keeps category-first syntax and normalises names');
    $row->{id_user}=undef;
    $run->('mbChownCommand_ctx','thé','ami'); $a->is($row->{id_user},2,'Master can assign system-owned command');
    $row->{action}='PRIVMSG %c %rand{2,1}'; $bot->{sent}=[];
    $a->is(mbDbCommand($bot,$message,'#teuk','Teuk','thé'),1,'invalid stored template handled without unrelated fallback');
    $a->is($row->{hits},$hits,'invalid stored template not counted');
    $a->is(scalar @{$bot->{sent}},0,'invalid stored template sends nothing');
    $row->{action}='PRIVMSG #elsewhere bad';
    mbDbCommand($bot,$message,'#teuk','Teuk','thé');
    $a->is(scalar @{$bot->{sent}},0,'stored target cannot redirect output');
    $row->{action}='PRIVMSG %c hello %n';
    $db->{execute_fail}=qr/^UPDATE PUBLIC_COMMANDS SET hits/; $bot->{sent}=[];
    $a->is(mbDbCommand($bot,$message,'#teuk','Teuk','thé'),1,'statistics failure still handles a valid command');
    $a->is($bot->{sent}[0][2],'hello Teuk','statistics failure still sends response');
    delete $db->{execute_fail};
    $row->{action}='PRIVMSG %c %r';
    my $private=Mediabot::Context->new(bot=>$bot,nick=>'Teuk',channel=>undef,message=>$message,args=>['thé']);
    $bot->{sent}=[];mbDbTestCommand_ctx($private);
    $a->like($bot->{sent}[0][2],qr/: Teuk$/,'private random nick preview uses caller');
    $a->is($random_nicks,0,'private preview never queries undefined channel');
    $user->{auth}=0;
    for my $handler (qw(mbDbAddCommand_ctx mbDbModCommand_ctx mbDbRemCommand_ctx mbDbMvCommand_ctx mbChownCommand_ctx mbDbHoldCommand_ctx mbDbAddCategoryCommand_ctx mbDbTestCommand_ctx)) {
        my $count=@{$db->{sql}}; $run->($handler,'thé','off','general','bad');
        $a->is(scalar @{$db->{sql}},$count,'unauthenticated administration or preview makes no DB call');
    }
    $a->like($run->('mbDbCommandVars_ctx'),qr/%rand\{min,max\}.*%yesno%/,'cmdvars publicly describes richer templates');
    $user->{auth}=1;
    $db->{prepare_fail}=qr/^SELECT action, active/;
    $a->like($run->('mbDbTestCommand_ctx','thé'),qr/Database error/,'preview prepare failure handled');
    delete $db->{prepare_fail};
    $db->{execute_fail}=qr/^SELECT action, active/;
    $a->like($run->('mbDbTestCommand_ctx','thé'),qr/Database error/,'preview execute failure handled');
    delete $db->{execute_fail};
    $a->like($run->('mbDbTestCommand_ctx','missing'),qr/does not exist/,'missing preview handled');
    my $before=@{$db->{sql}};
    mbDbModCommand($bot,$message,'Teuk','thé','message','general','%rand{5,1}');
    $a->is(scalar(@{$db->{sql}}),$before,'legacy modcmd shares template validation');
    mbDbModCommand($bot,$message,'Teuk',"the\x{301}",'message','general','legacy %n');
    $a->is($row->{action},'PRIVMSG %c legacy %n','legacy modcmd normalises Unicode lookup too');
    $run->('mbDbRemCommand_ctx',"the\x{301}"); $a->ok(!exists $db->{rows}{'thé'},'Unicode deletion works for Master');
    $a->ok(!grep({ !$_->{finished} } @{$db->{handles}}),'all statement handles finished including failure paths');
})->(bless {}, 'MB807Assert');
done_testing();
