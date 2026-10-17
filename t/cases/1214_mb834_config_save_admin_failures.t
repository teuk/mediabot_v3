use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib '.', 't/lib';
use MockUser;
use Mediabot::Conf;
use Mediabot::AdminCommands ();

{
    package MB834Context;
    sub new { my ($class, %args) = @_; bless \%args, $class }
    sub bot { $_[0]{bot} }
    sub nick { 'owner' }
    sub channel { undef }
    sub args { $_[0]{args} }
    sub user { $_[0]{user} }
    sub message { undef }
    sub require_level { $_[0]{user}->is_authenticated && $_[0]{user}->has_level($_[1]) }
}
{
    package MB834Log;
    sub new { bless {lines=>[], debug_level=>2}, shift }
    sub log { push @{$_[0]{lines}}, $_[2]; 1 }
}
{
    package MB834IRC;
    sub nick_folded { 'mediabot' }
}

no warnings qw(redefine once);
local *Mediabot::AdminCommands::botNotice = sub { push @{$_[0]{notices}}, $_[2]; 1 };
local *Mediabot::AdminCommands::noticeConsoleChan = sub { 1 };
local *Mediabot::AdminCommands::logBot = sub { 1 };

my $dir = tempdir(CLEANUP=>1);
my $serial = 0;
sub fixture {
    my ($args, $role, $auth) = @_;
    my $path = "$dir/config-".(++$serial).'.conf';
    open my $fh, '>', $path or die 'fixture';
    print {$fh} "[main]\nMAIN_PROG_DEBUG=2\n[openai]\nMODEL=gpt-4o\nTEMPERATURE=0.6\n";
    close $fh;
    my $bot = {conf=>Mediabot::Conf->new({},$path), logger=>MB834Log->new,
        irc=>bless({},'MB834IRC'), notices=>[]};
    my $ctx = MB834Context->new(bot=>$bot,args=>$args,
        user=>MockUser->new(level=>$role//'Owner',auth=>defined($auth)?$auth:1));
    return ($path,$bot,$ctx);
}

my @commands = (
    ['set', [qw(set model gpt-4o-mini)], 'OpenAI model set to', 'openai.MODEL', 'gpt-4o-mini'],
    ['reset', [qw(reset model)], 'OpenAI model reset to default', 'openai.MODEL', 'gpt-4o-mini'],
    ['profile', [qw(profile safe)], "OpenAI profile 'safe' applied", 'openai.MODEL', 'gpt-4o-mini'],
    ['debug', ['4'], 'Debug level set to 4', 'main.MAIN_PROG_DEBUG', '4'],
);
sub invoke {
    my ($name,$ctx)=@_;
    return $name eq 'debug'
        ? Mediabot::AdminCommands::debug_ctx($ctx)
        : Mediabot::AdminCommands::openai_ctx($ctx);
}

for my $command (@commands) {
    my ($name,$args,$success,$key,$value)=@$command;
    for my $failure ('false','exception','revision') {
        my ($path,$bot,$ctx)=fixture($args);
        if ($failure eq 'revision') {
            open my $fh, '>>', $path or die 'fixture edit'; print {$fh} "\n# operator edit\n"; close $fh;
        }
        my $ok;
        if ($failure eq 'revision') { $ok=eval { invoke($name,$ctx); 1 } }
        else {
            local *Mediabot::Conf::save = $failure eq 'false'
                ? sub { return undef } : sub { die "PRIVATE_CREDENTIAL_CONTENT\n" };
            $ok=eval { invoke($name,$ctx); 1 };
        }
        ok($ok, "$name/$failure: save failure cannot escape the IRC handler");
        my $notices=join("\n",@{$bot->{notices}});
        like($notices,qr/Configuration save failed/,"$name/$failure: requester receives a failure notice");
        unlike($notices,qr/\Q$success\E/,"$name/$failure: no false success notice");
        unlike($notices.join("\n",@{$bot->{logger}{lines}}),qr/PRIVATE_CREDENTIAL_CONTENT/,"$name/$failure: diagnostics reveal no dependency exception text");
        is(Mediabot::Conf->new({},$path)->get($key),$name eq 'debug'?'2':'gpt-4o',"$name/$failure: active file retains the original value");
        is($bot->{logger}{debug_level},2,"$name/$failure: live logger level is not advanced after save failure");
        like(join("\n",@{$bot->{logger}{lines}}),
            $failure eq 'revision'?qr/reason=revision_conflict/:qr/reason=save_rejected/,
            "$name/$failure: server receives a bounded failure code");
    }
    {
        my ($path,$bot,$ctx)=fixture($args);
        ok(eval { invoke($name,$ctx); 1 },"$name: successful path still returns normally");
        like(join("\n",@{$bot->{notices}}),qr/\Q$success\E/,"$name: historical success notice remains");
        is(Mediabot::Conf->new({},$path)->get($key),$value,"$name: real configuration value is persisted");
        is($bot->{logger}{debug_level},$name eq 'debug'?4:2,"$name: logger changes only on successful debug persistence");
    }
    for my $identity (['Master',1],['Owner',0]) {
        my ($path,$bot,$ctx)=fixture($args,@$identity);
        my $calls=0;
        {
            local *Mediabot::Conf::save = sub { $calls++; die 'must not write' };
            ok(eval { invoke($name,$ctx); 1 },"$name: denied identity returns safely");
        }
        is($calls,0,"$name: unauthenticated/non-Owner caller cannot reach save");
        is(Mediabot::Conf->new({},$path)->get($key),$name eq 'debug'?'2':'gpt-4o',"$name: denied identity cannot modify persistence");
    }
}
done_testing;
