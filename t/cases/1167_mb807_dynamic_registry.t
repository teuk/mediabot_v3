use strict;
use warnings;
use utf8;
BEGIN { use FindBin qw($Bin); unshift @INC, "$Bin/../lib", "$Bin/../.."; }
use Mediabot::Mediabot;
use Mediabot::Context;
use Mediabot::CommandRegistry;
use Mediabot::BuiltinCommandCatalog qw(public_command_names private_command_names catalogue_entries);
use MockBot;
use MockUser;
use MockMessage;

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
    for my $entry (grep { $_->{source} eq 'public' && $_->{name} =~ /^(?:testcmd|cmdvars)$/ } catalogue_entries()) {
        $a->ok(!$entry->{migration_fallback}, 'new dynamic helpers have no historical migration fallback');
    }
    my %public=Mediabot::_builtin_public_command_handlers();
    my %private=Mediabot::_builtin_private_command_handlers();
    my %public_names=map {$_=>1} public_command_names();
    my %private_names=map {$_=>1} private_command_names();
    for my $name (qw(testcmd cmdvars)) {
        $a->ok(ref($public{$name}) eq 'CODE' && ref($private{$name}) eq 'CODE', "$name executable in both registry factories");
        $a->ok($public_names{$name} && $private_names{$name}, "$name exposed in both catalogues");
    }
    my $user=MockUser->new(auth=>1, level=>'Master');
    my $bot=MockBot->new(mock_user=>$user);
    my @sent;
    no warnings 'redefine';
    local *Mediabot::DBCommands::botNotice=sub {push @sent, $_[2]};
    for my $name ('météo',"me\x{301}te\x{301}o",'actualités','hélp') {
        @sent=();
        $a->ok(!defined(Mediabot::DBCommands::_new_dynamic_name($bot,'Teuk',$name)), 'real public folding prevents accented built-in collision');
        $a->like(join(' ',@sent),qr/reserved/, 'reserved spelling receives a useful notice');
    }
    my $ctx=Mediabot::Context->new(bot=>$bot,nick=>'Teuk',channel=>'#teuk',args=>[]);
    @sent=();$public{cmdvars}->($ctx);
    $a->like(join(' ',@sent),qr/%rand\{min,max\}.*%choose\{tea\|coffee\|water\}/, 'public registry handler reaches variable guide');
    @sent=();$private{cmdvars}->($ctx);
    $a->like(join(' ',@sent),qr/holdcmd.*off/, 'private registry handler reaches guide');
    my %help=Mediabot::_mbHelpInternalCommands();
    $a->like($help{addcmd}{syntax},qr/<command> <message\|action> <category> <text>/, 'addcmd help follows real parser');
    $a->like($help{modcmd}{syntax},qr/<command> <message\|action> <category> <text>/, 'modcmd help follows real parser');
    $a->like($help{chcatcmd}{syntax},qr/<new_category> <command>/, 'category help retains actual legacy order');
    $a->like($help{holdcmd}{syntax},qr/on\|off\|toggle/, 'help explains reactivation and toggle');
    $a->ok($help{testcmd} && $help{cmdvars}, 'new operations have help metadata');
})->(bless {}, 'MB807Assert');
done_testing();
