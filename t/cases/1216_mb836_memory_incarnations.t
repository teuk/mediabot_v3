use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP ();
use Mediabot::AI::MetaMemory;

my $dir=tempdir(CLEANUP=>1);
my $path="$dir/memory.json";
my $now=1000;
sub store { Mediabot::AI::MetaMemory->new(path=>$path,ttl=>300,clock=>sub{$now}) }
sub bytes { open my $fh,'<:raw',$path or die $!;local $/;return <$fh> }
sub publish { my ($state)=@_;open my $fh,'>:raw',$path or die $!;
    print {$fh} JSON::PP->new->utf8->canonical->encode($state);close $fh or die $! }

my $m=store();
my $old=$m->begin_turn('dev:network:#room','alice!u!host','Expired private question',100,'Alice');
ok($m->current($old),'new ticket is current');
$now+=301;
my $new=$m->begin_turn('dev:network:#room','alice!u!host','Fresh discussion',100,'Alice');
ok(!$m->current($old),'same actor and speaker cannot revive a ticket after room expiry');
my $before=bytes();
ok(!$m->commit_turn($old,'Expired delayed answer'),'late result cannot commit into recreated room');
is(bytes(),$before,'rejecting the late result does not change stored history or usage');
ok(store()->current($new),'current incarnation survives another store object');
ok($m->commit_turn($new,'Fresh answer'),'new room still accepts its own delivered result');
my $next=$m->begin_turn('dev:network:#room','bob!u!other','Continue',100,'Bob');
my $context=join ' ',map{$_->{content}}@{$next->{messages}};
like($context,qr/Fresh discussion.*Fresh answer/,'fresh conversation is preserved');
unlike($context,qr/Expired/,'expired context cannot leak back through a delayed completion');
ok($m->rename_actor('bob!u!other','robert!u!other'),'observed rename succeeds');
ok($m->current($next),'rename does not cancel the current room incarnation');
ok($m->commit_turn($next,'Rename-safe answer'),'in-flight answer survives a legitimate rename');
ok($m->forget_actor('dev:network:#room','robert!u!other'),'personal erasure succeeds');
ok(!$m->current($next),'erasure still invalidates the pre-erasure epoch');
ok(!$m->commit_turn($next,'Erased delayed answer'),'erasure is not bypassed by a matching incarnation');

# A legacy version-1 room is upgraded in place on its next successful begin.
my $legacy=JSON::PP->new->utf8->decode(bytes());
delete $_->{incarnation} for values %{$legacy->{rooms}};
publish($legacy);
my $legacy_ticket={%$new};delete $legacy_ticket->{incarnation};
ok(!store()->current($legacy_ticket),'tickets without an incarnation fail closed');
my $migrated=store()->begin_turn('dev:network:#room','alice!u!host','After upgrade',100,'Alice');
like(join(' ',map{$_->{content}}@{$migrated->{messages}}),qr/Fresh answer/,
    'legacy history survives lazy migration without a reset');
is($migrated->{speaker},$new->{speaker},'legacy speaker identity is retained');
ok(store()->current($migrated),'migrated ticket is valid after reloading');
ok(!store()->current($new),'pre-migration ticket cannot attach to the migrated room');
is((stat($path))[2]&0777,0600,'migration retains private memory permissions');

for my $bad (undef,{},[],{%$migrated,scope=>[]},{%$migrated,epoch=>[]},
    {%$migrated,incarnation=>[]},{%$migrated,incarnation=>'wrong'}) {
    my $unchanged=bytes();
    my $current=eval{store()->current($bad)};
    ok(!$@ && !$current,'malformed ticket cannot become current');
    my $committed=eval{store()->commit_turn($bad,'Untrusted answer')};
    ok(!$@ && !$committed,'malformed ticket cannot commit');
    is(bytes(),$unchanged,'malformed ticket rejection preserves the file');
}

my $state=JSON::PP->new->utf8->decode(bytes());
my ($room)=values %{$state->{rooms}};
$room->{incarnation}=[];publish($state);my $corrupt=bytes();
ok(!eval{store()->begin_turn('dev:network:#room','alice','Question',100);1},
    'malformed persisted generation is refused');
is(bytes(),$corrupt,'malformed state is retained for recovery');

# Failure to create a fresh identity must not publish a half-created room.
unlink $path or die $!;
{
    no warnings qw(redefine once);
    local *Mediabot::AI::MetaMemory::_new_incarnation=sub{die "generation unavailable\n"};
    ok(!eval{store()->begin_turn('scope','alice','Question',100);1},
        'generation failure cannot create an unbound ticket');
    ok(!-e $path,'generation failure does not publish partial memory');
}
done_testing;
