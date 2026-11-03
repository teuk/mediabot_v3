use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;
use JSON::PP;
use Scalar::Util qw(refaddr);

# Exercise the real hash-copy boundary: plugin-owned tied metadata can throw
# during enumeration/fetch or register another command before returning data.
{
    package MB1082::Metadata;
    sub TIEHASH {my ($class,%args)=@_;bless {data=>{first=>'one',second=>'two'},%args},$class}
    sub FIRSTKEY {
        my $s=shift;++$s->{copies};$s->{index}=0;
        my $hook=delete $s->{hook};$hook->() if $hook;
        die $s->{error} if ($s->{fail}//'') eq 'first';
        return 'first';
    }
    sub NEXTKEY {
        my $s=shift;
        die $s->{error} if ($s->{fail}//'') eq 'next';
        return ++$s->{index}==1 ? 'second':undef;
    }
    sub FETCH {
        my ($s,$key)=@_;
        die $s->{error} if ($s->{fail}//'') eq 'fetch';
        return $s->{data}{$key};
    }
    sub SCALAR {2}
}

sub _registry1082 {
    my $reg=Mediabot::CommandRegistry->new;
    for my $source (qw(public private)) {
        $reg->register_command(name=>'spell',source=>$source,aliases=>['oldspell','s'],
            handler=>sub {'spell-v1'},metadata=>{version=>1},plugin=>'original');
        $reg->register_command(name=>'other',source=>$source,aliases=>['o'],handler=>sub {'other-v1'});
    }
    return $reg;
}
sub _view1082 {
    my $reg=shift;
    my @entries;
    for my $entry ($reg->list) {
        push @entries,{map {$_=>$entry->{$_}} qw(name source aliases metadata category description level chanset plugin)};
        $entries[-1]{result}=$entry->{handler}->();
    }
    my %routes;
    for my $source (qw(public private)) {
        for my $name (qw(spell oldspell s newspell fresh other o intruder)) {
            my $entry=$reg->command_for($name,$source);
            $routes{$source}{$name}=$entry ? [$entry->{name},$reg->handler_for($name,$source)->()] : undef;
        }
    }
    return {entries=>\@entries,routes=>\%routes,count=>$reg->count};
}

my $case=sub {
    my ($assert)=@_;
    my $root=File::Spec->catdir($Bin,'..','..');unshift @INC,$root;
    require Mediabot::CommandRegistry;
    my $json=JSON::PP->new->canonical;
    my $check=sub {
        my ($got,$wanted,$label)=@_;
        my $actual=$json->encode($got);my $expected=$json->encode($wanted);
        $assert->($actual eq $expected,$label.($actual eq $expected?'':" got=$actual expected=$expected"));
    };
    my $reg=_registry1082();
    my $before=_view1082($reg);
    my $old=$reg->command_for('spell','public');
    my $ok=eval {$reg->register_command(name=>'spell',source=>'public',aliases=>['o'],
        replace=>1,handler=>sub {'bad'});1};my $error=$@;
    $check->([!$ok && $error=~/already points to 'other'/?1:0,_view1082($reg),
        refaddr($reg->command_for('spell','public'))==refaddr($old)?1:0],
        [1,$before,1],'conflicting alias replacement preserves every old command, alias, metadata, handler and source');

    $ok=eval {$reg->register_command(name=>'spell',source=>'public',aliases=>['other'],
        replace=>1,handler=>sub {'bad'});1};$error=$@;
    $check->([!$ok && $error=~/conflicts with command 'other'/?1:0,_view1082($reg)],
        [1,$before],'canonical-name conflict also leaves the complete dispatch namespace unchanged');

    $reg->register_command(name=>'spell',source=>'public',aliases=>['newspell'],
        replace=>1,handler=>sub {'spell-v2'});
    $check->([$reg->has_command('oldspell','public'),$reg->has_command('s','public'),
        $reg->handler_for('newspell','public')->(),$reg->handler_for('other','public')->(),
        $reg->handler_for('s','private')->(),$reg->count],[0,0,'spell-v2','other-v1','spell-v1',4],
        'successful replacement installs the new handler and removes only its stale aliases');

    {
        my @bad;
        for my $source (qw(public private)) {for my $replace (0,1) {for my $stage (qw(first next fetch)) {
            my $r=_registry1082();my $prior=$json->encode(_view1082($r));
            my $entry=$r->command_for('spell',$source);
            my $exception=bless {stage=>$stage},'MB1082::MetadataError';
            tie my %meta,'MB1082::Metadata',fail=>$stage,error=>$exception;
            my $ok=eval {$r->register_command(name=>$replace?'spell':'fresh',source=>$source,
                aliases=>['newspell'],handler=>sub {'unpublished'},replace=>$replace,metadata=>\%meta);1};
            my $error=$@;
            push @bad,[$source,$replace,$stage] unless !$ok && refaddr($error)==refaddr($exception)
                && $json->encode(_view1082($r)) eq $prior
                && refaddr($r->command_for('spell',$source))==refaddr($entry);
        }}}
        $check->(\@bad,[],
            'MB1082: FIRSTKEY/NEXTKEY/FETCH failures preserve the original exception and complete registry for registration/replacement in both sources');
    }
    for my $collision (qw(alias canonical)) {
        my @bad;
        for my $source (qw(public private)) {for my $replace (0,1) {
            my $r=_registry1082();my $reference=_registry1082();my $entry=$r->command_for('spell',$source);
            my $install=sub {
                $_[0]->register_command(name=>$collision eq 'alias'?'intruder':'newspell',
                    source=>$source,aliases=>$collision eq 'alias'?['newspell']:[],
                    handler=>sub {'inner-command'},metadata=>{inner=>1});
            };
            $install->($reference);
            my $calls=0;
            tie my %meta,'MB1082::Metadata',hook=>sub {$calls++;$install->($r)};
            my $ok=eval {$r->register_command(name=>$replace?'spell':'fresh',source=>$source,
                aliases=>['newspell'],handler=>sub {'unpublished'},replace=>$replace,metadata=>\%meta);1};
            my $error=$@;
            push @bad,[$source,$replace] unless !$ok && $error=~/already points|conflicts with command/
                && $calls==1 && $json->encode(_view1082($r)) eq $json->encode(_view1082($reference))
                && refaddr($r->command_for('spell',$source))==refaddr($entry);
        }}
        $check->(\@bad,[],
            "MB1082: metadata reentry registering a competing $collision is retained and cannot be stolen by the outer registration/replacement");
    }
    {
        my $r=_registry1082();my $nested={kept=>1};
        tie my %meta,'MB1082::Metadata';my $tied=tied %meta;$tied->{data}{first}=$nested;
        my $entry=$r->register_command(name=>' Spell ',source=>' PRIVATE ',
            aliases=>['NEWSPELL','newspell','spell'],handler=>sub {'tied-v2'},replace=>1,
            metadata=>\%meta,category=>'games',description=>'new description',level=>'Master',chanset=>'Games',plugin=>'replacement');
        $tied->{data}{second}='changed later';
        $check->([$tied->{copies},tied(%{$entry->{metadata}})?1:0,$entry->{metadata}{second},
            refaddr($entry->{metadata}{first})==refaddr($nested)?1:0,
            [map {$entry->{$_}} qw(name source category description level chanset plugin)],
            [$r->aliases_for('spell','private')],$r->handler_for('newspell','private')->(),
            $r->has_command('s','private'),$r->handler_for('s','public')->()],
            [1,0,'two',1,['spell','private','games','new description','Master','Games','replacement'],
             ['newspell'],'tied-v2',0,'spell-v1'],
            'MB1082: successful tied metadata is copied once with historical shallow-copy, metadata fields, normalization and source isolation intact');
    }
};

if (caller) {return $case}
my ($tests,$fail)=(0,0);
$case->(sub {my ($ok,$name)=@_;++$tests;print($ok?"ok $tests - $name\n":"not ok $tests - $name\n");++$fail unless $ok});
print "1..$tests\n";
exit($fail?1:0);
