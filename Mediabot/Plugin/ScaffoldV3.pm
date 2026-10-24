package Mediabot::Plugin::ScaffoldV3;
use strict;
use warnings;
use JSON::PP ();
use File::Spec;
use File::Path qw(remove_tree);
use Fcntl qw(O_WRONLY O_CREAT O_EXCL);

sub create {
    my (%args)=@_;
    my ($parent,$name,$command)=@args{qw(directory name command)};
    die "Invalid package name\n" unless defined($name) && !ref($name)
        && $name =~ /\A[a-z][a-z0-9]*(?:-[a-z0-9]+)*\z/ && length($name)<=48;
    $command //= $name =~ s/-/_/gr;
    die "Invalid command name\n" unless !ref($command) && $command =~ /\A[a-z][a-z0-9_]{0,47}\z/;
    die "Existing directory required\n" unless defined($parent) && !ref($parent) && -d $parent;
    $parent=File::Spec->rel2abs($parent);
    my $walk=File::Spec->rootdir;
    for my $part (File::Spec->splitdir($parent)) {
        next unless length($part);die "Unsafe parent path\n" if $part eq '..';
        $walk=File::Spec->catdir($walk,$part);die "Symlink parent refused\n" if -l $walk;
    }
    my $dest=File::Spec->catdir($parent,$name);
    # mkdir is exclusive even for a racing creator or dangling symlink.
    mkdir($dest,0700) or die "Destination exists or cannot be created\n";
    my $class='Mediabot::Plugin::V3::'.join('',map {ucfirst($_)} split /-/,$name);
    my $manifest={api=>3,name=>$name,version=>'0.1.0',description=>'A small explicit channel greeting.',
        runtime=>{kind=>'perl',entrypoint=>'lib/Greeting.pm',class=>$class},activation=>{default=>'off'},
        capabilities=>['irc.reply'],events=>[],jobs=>{},commands=>{$command=>{source=>'public',level=>0,
            help=>'Show the configured channel greeting.',handler=>'command_greet',aliases=>[]}},
        config_schema=>{greeting=>{type=>'string',default=>'Hello from this channel.',min_length=>1,max_length=>160}}};
    my $code=<<'CODE';
package __CLASS__;
use strict;
use warnings;
use utf8;
sub new {
    my ($class,%args)=@_;
    die "PluginContext required\n" unless ref($args{context})
        && eval {$args{context}->isa('Mediabot::PluginContext')};
    return bless {started=>0},$class;
}
sub start {$_[0]{started}=1;return 1}
sub stop {$_[0]{started}=0;return 1}
sub command_greet {
    my ($self,$context,$invocation)=@_;
    return unless $self->{started};
    return $context->reply($invocation,$invocation->config_value('greeting'));
}
1;
CODE
    $code =~ s/__CLASS__/$class/g;
    my $readme="# $name\n\nDefault-off API v3 example; capability: irc.reply only.\n"
        ."No database, HTTP, events, jobs or automatic messages.\n\n"
        ."Try first on development #test, as an Owner in Partyline:\n\n```text\n"
        .".plugins loadv3 $name irc.reply\n.plugins policy $name #test observe\n.plugins enable $name\n"
        ."```\n\nIn #test, invoke !$command: observe remains silent. Then explicitly choose\n"
        .".plugins policy $name #test on and invoke !$command again.\n"
        ."Use the actual public prefix of your instance. Other channels stay off.\n\n"
        ."Rollback: .plugins policy $name #test off, .plugins disable $name,\n"
        ."then .plugins unload $name. Existing core permissions still apply.\n"
        ."For a complete checked walkthrough see docs/PLUGIN_WORKSHOP.md.\n";
    my $ok=eval {
        mkdir(File::Spec->catdir($dest,'lib'),0755) or die 'directory';
        my %files=('plugin.json'=>JSON::PP->new->canonical->pretty->encode($manifest),
            'lib/Greeting.pm'=>$code,'README.md'=>$readme);
        for my $relative (sort keys %files) {
            my $file=File::Spec->catfile($dest,$relative);
            sysopen(my $fh,$file,O_WRONLY|O_CREAT|O_EXCL,0600) or die 'file';
            print {$fh} $files{$relative} or die 'write';close($fh) or die 'close';
            chmod(0644,$file) or die 'mode';
        }
        chmod(0755,$dest) or die 'mode';1;
    };
    unless ($ok) {remove_tree($dest);die "Package creation failed\n"}
    return {directory=>$dest,name=>$name,command=>$command};
}
1;
