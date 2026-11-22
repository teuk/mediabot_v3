package Mediabot::Plugin::ScaffoldV3;
use strict;
use warnings;
use JSON::PP ();
use Mediabot::Plugin::ManifestV3;
use Mediabot::Plugin::ScaffoldFiles ();

sub create {
    my (%args)=@_;
    my ($parent,$name,$command)=@args{qw(directory name command)};
    my $language = $args{language} // 'perl';
    my %entrypoint = (perl => 'lib/Greeting.pm', python => 'lib/greeting.py',
        tcl => 'lib/greeting.tcl');
    die "Package language must be perl, python or tcl\n"
        unless !ref($language) && exists $entrypoint{$language};
    die "Invalid package name\n" unless defined($name) && !ref($name)
        && $name =~ /\A[a-z][a-z0-9]*(?:-[a-z0-9]+)*\z/ && length($name)<=48;
    $command //= $name =~ s/-/_/gr;
    die "Invalid command name\n" unless !ref($command) && $command =~ /\A[a-z][a-z0-9_]*\z/;
    my $class='Mediabot::Plugin::V3::'.join('',map {ucfirst($_)} split /-/,$name);
    my $native = $language eq 'perl';
    my $manifest={api=>3,name=>$name,version=>'0.1.0',description=>'A small explicit channel greeting.',
        runtime=>{kind=>$language,entrypoint=>$entrypoint{$language},
            ($native ? (class => $class) : ())},activation=>{default=>'off'},
        capabilities=>['irc.reply'],events=>[],jobs=>{},commands=>{$command=>{source=>'public',level=>0,
            help=>'Show the configured channel greeting.',handler=>'command_greet',aliases=>[]}},
        config_schema=>{greeting=>{type=>'string',default=>($native ? 'Hello from this channel.' : 'Bonjour'),
            min_length=>1,max_length=>160}}};
    Mediabot::Plugin::ManifestV3->validate($manifest, expected_name => $name);
    my $code;
    if ($native) {
        $code = _perl_source($class);
    } else {
        require Mediabot::Plugin::ScriptWorkshop;
        $code = Mediabot::Plugin::ScriptWorkshop::greeting_source($language, 'greeting');
    }
    my $readme="# $name\n\nDefault-off API v3 example; capability: irc.reply only.\n"
        ."No database, HTTP, events, jobs or automatic messages.\n\n"
        ."From the Mediabot checkout, verify your changes before installing the plugin:\n\n```bash\n"
        ."perl tools/plugin_v3_workshop.pl --validate $name --grant irc.reply --directory plugins\n"
        ."```\n\nUse the parent directory you passed to --create if it differs from plugins.\n\n"
        ."Try first on development #test, as an Owner in Partyline:\n\n```text\n"
        .".plugins loadv3 $name irc.reply\n.plugins policy $name #test observe\n.plugins enable $name\n"
        ."```\n\nIn #test, invoke !$command: observe remains silent. Then explicitly choose\n"
        .".plugins policy $name #test on and invoke !$command again.\n"
        ."Use the actual public prefix of your instance. Other channels stay off.\n\n"
        ."Rollback: .plugins policy $name #test off, .plugins disable $name,\n"
        ."then .plugins unload $name. Existing core permissions still apply.\n"
        ."For a complete checked walkthrough see docs/PLUGIN_WORKSHOP.md.\n";
    my %files = (
        'plugin.json' => JSON::PP->new->canonical->pretty->encode($manifest),
        $entrypoint{$language} => $code,
        'README.md' => $readme,
    );
    my $dest = Mediabot::Plugin::ScaffoldFiles::write_package($parent, $name, \%files, 'lib');
    return {directory=>$dest,name=>$name,command=>$command};
}

sub _perl_source {
    my ($class) = @_;
    my $code = <<'CODE';
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
    return $code;
}

1;
